
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity Calculator is
    port (
        clk  : in  std_logic;
        BTNU, BTND, BTNL, BTNR, BTNC : in std_logic;
        SW   : in  std_logic_vector(15 downto 0);
        SEG  : out std_logic_vector(6 downto 0);
        AN   : out std_logic_vector(7 downto 0);
        DP   : out std_logic
    );
end entity;

architecture RTL of Calculator is

    -- Main FSM
    type state_t is (
        ENTER_A, ENTER_B, PREPARE,
        DIVIDE_BITS, FORMAT_DECIMAL, RESULT_PAGE
    );
    signal state : state_t := ENTER_A;

    -- Input registers:
    -- Maximum 3 integer + 2 fractional digits
    signal a_mag, b_mag :
        integer range 0 to 99999 := 0;

    signal a_int, b_int :
        integer range 0 to 3 := 0;

    signal a_frac, b_frac :
        integer range 0 to 2 := 0;

    signal a_dot, b_dot : std_logic := '0';
    signal a_neg, b_neg : std_logic := '0';

    -- Debounced input levels
    signal sw_level : std_logic_vector(15 downto 0);

    signal u_level, d_level, l_level,
           r_level, c_level : std_logic;

    signal old_u, old_d, old_l,
           old_r, old_c : std_logic := '0';

    signal old_back, old_dot : std_logic := '0';

    -- Decode SW0-SW9
    signal sw_count : integer range 0 to 10 := 0;
    signal sw_digit : integer range 0 to 9 := 0;
    signal digit_armed : std_logic := '1';

    -- Long Enter hold: 1 second
    constant HOLD_LIMIT : natural := 100000000;

    signal hold_count :
        natural range 0 to HOLD_LIMIT := 0;

    signal held_reset : std_logic := '0';

    -- Magnitudes scaled by 100
    signal a_scaled, b_scaled :
        integer range 0 to 99999 := 0;

    -- 0=+, 1=-, 2=*, 3=/
    signal chosen_op : integer range 0 to 3 := 0;

    signal result_negative : std_logic := '0';
    signal error_flag : std_logic := '0';

    signal result_cents :
        integer range 0 to 9999999 := 0;

    -- Sequential binary division
    signal numerator_bits :
        unsigned(33 downto 0) := (others => '0');

    signal denominator :
        integer range 1 to 99999 := 1;

    signal remainder_r :
        integer range 0 to 199998 := 0;

    signal quotient_r :
        unsigned(33 downto 0) := (others => '0');

    signal bit_index : integer range 0 to 33 := 33;

    -- Decimal result conversion
    type digits_t is array(0 to 6)
        of integer range 0 to 9;

    signal out_digits : digits_t := (others => 0);

    type places_t is array(0 to 6) of integer;

    constant PLACES : places_t := (
        1, 10, 100, 1000,
        10000, 100000, 1000000
    );

    signal format_rest :
        integer range 0 to 9999999 := 0;

    signal format_pos :
        integer range 0 to 6 := 6;

    -- 7-Segment display
    type segs_t is array(0 to 7)
        of std_logic_vector(6 downto 0);

    signal disp : segs_t;

    signal refresh :
        unsigned(16 downto 0) := (others => '0');

    signal scan : integer range 0 to 7;

    signal dp_bits :
        std_logic_vector(7 downto 0);

    -- 7-segment decoder: active low
    function seg7(n : integer)
        return std_logic_vector is
    begin
        case n is
            when 0 => return "1000000";
            when 1 => return "1111001";
            when 2 => return "0100100";
            when 3 => return "0110000";
            when 4 => return "0011001";
            when 5 => return "0010010";
            when 6 => return "0000010";
            when 7 => return "1111000";
            when 8 => return "0000000";
            when 9 => return "0010000";
            when 10 => return "0111111"; -- minus
            when 11 => return "0000110"; -- E
            when 12 => return "0101111"; -- r
            when others => return "1111111";
        end case;
    end function;

    -- Convert input to fixed-point x100
    function scale100(
        mag, frac : integer
    ) return integer is
    begin
        case frac is
            when 0 =>
                return mag * 100;
            when 1 =>
                return mag * 10;
            when others =>
                return mag;
        end case;
    end function;

begin

    ----------------------------------------
    -- BUTTON DEBOUNCE
    ----------------------------------------

    buttons_u : entity work.ButtonLevel
        port map(clk, BTNU, u_level);

    buttons_d : entity work.ButtonLevel
        port map(clk, BTND, d_level);

    buttons_l : entity work.ButtonLevel
        port map(clk, BTNL, l_level);

    buttons_r : entity work.ButtonLevel
        port map(clk, BTNR, r_level);

    buttons_c : entity work.ButtonLevel
        port map(clk, BTNC, c_level);

    ----------------------------------------
    -- SWITCH DEBOUNCE
    ----------------------------------------

    debounce_switch : for i in 0 to 15 generate
        inst : entity work.ButtonLevel
            port map(
                clk,
                SW(i),
                sw_level(i)
            );
    end generate;

    ----------------------------------------
    -- SWITCH DECODER
    ----------------------------------------

    process(all)
        variable n, d : integer;
    begin
        n := 0;
        d := 0;

        for i in 0 to 9 loop
            if sw_level(i) = '1' then
                n := n + 1;
                d := i;
            end if;
        end loop;

        sw_count <= n;
        sw_digit <= d;
    end process;

    ----------------------------------------
    -- MAIN FSM
    ----------------------------------------

    process(clk)

        variable va, vb, vr, rr : integer;
        variable neg_v : std_logic;

        variable temp_u :
            unsigned(67 downto 0);

        variable rem_next : integer;
        variable quot_next :
            unsigned(33 downto 0);

    begin
        if rising_edge(clk) then

            -- Previous button states
            old_u <= u_level;
            old_d <= d_level;
            old_l <= l_level;
            old_r <= r_level;
            old_c <= c_level;

            old_back <= sw_level(10);
            old_dot <= sw_level(11);

            -- Re-arm digit input when
            -- all digit switches are OFF
            if sw_count = 0 then
                digit_armed <= '1';
            end if;

            ----------------------------------
            -- LONG ENTER RESET
            ----------------------------------

            if c_level = '1' then

                if held_reset = '0' then

                    if hold_count = HOLD_LIMIT - 1 then

                        state <= ENTER_A;

                        a_mag <= 0;
                        b_mag <= 0;

                        a_int <= 0;
                        b_int <= 0;

                        a_frac <= 0;
                        b_frac <= 0;

                        a_dot <= '0';
                        b_dot <= '0';

                        a_neg <= '0';
                        b_neg <= '0';

                        a_scaled <= 0;
                        b_scaled <= 0;

                        chosen_op <= 0;
                        result_negative <= '0';

                        error_flag <= '0';
                        result_cents <= 0;

                        out_digits <= (others => 0);

                        numerator_bits <= (others => '0');
                        quotient_r <= (others => '0');

                        remainder_r <= 0;
                        format_rest <= 0;
                        format_pos <= 6;

                        digit_armed <= '0';

                        held_reset <= '1';
                        hold_count <= HOLD_LIMIT;

                    else
                        hold_count <= hold_count + 1;
                    end if;

                end if;

            else

                hold_count <= 0;

                ----------------------------------
                -- SHORT ENTER ON RELEASE
                ----------------------------------

                if old_c = '1' and
                   held_reset = '0' then

                    -- New calculation after result
                    if state = RESULT_PAGE then

                        state <= ENTER_A;

                        a_mag <= 0;
                        b_mag <= 0;

                        a_int <= 0;
                        b_int <= 0;

                        a_frac <= 0;
                        b_frac <= 0;

                        a_dot <= '0';
                        b_dot <= '0';

                        a_neg <= '0';
                        b_neg <= '0';

                        result_negative <= '0';
                        error_flag <= '0';
                        result_cents <= 0;

                        digit_armed <= '0';

                    elsif sw_level(15) = '0' then

                        --------------------------------
                        -- ENTER A
                        --------------------------------

                        if state = ENTER_A then

                            if sw_count = 1 and
                               digit_armed = '1' then

                                if (a_dot = '0' and a_int < 3)
                                   or
                                   (a_dot = '1' and a_frac < 2) then

                                    -- Avoid leading zero
                                    if a_dot = '0' and
                                       a_int = 1 and
                                       a_mag = 0 then

                                        a_mag <= sw_digit;

                                    else

                                        a_mag <=
                                            a_mag * 10 + sw_digit;

                                        if a_dot = '0' then
                                            a_int <= a_int + 1;
                                        else
                                            a_frac <= a_frac + 1;
                                        end if;

                                    end if;

                                    if a_int = 0 and
                                       a_dot = '0' then
                                        a_int <= 1;
                                    end if;

                                    digit_armed <= '0';

                                end if;

                            elsif sw_count = 0 and
                                  sw_level(10) = '0' and
                                  sw_level(11) = '0' and
                                  a_int > 0 then

                                -- Store A and move to B
                                state <= ENTER_B;

                                a_scaled <=
                                    scale100(a_mag, a_frac);

                                b_mag <= 0;
                                b_int <= 0;
                                b_frac <= 0;

                                b_dot <= '0';
                                b_neg <= '0';

                                digit_armed <= '1';

                            end if;

                        --------------------------------
                        -- ENTER B
                        --------------------------------

                        elsif state = ENTER_B then

                            if sw_count = 1 and
                               digit_armed = '1' then

                                if (b_dot = '0' and b_int < 3)
                                   or
                                   (b_dot = '1' and b_frac < 2) then

                                    -- Avoid leading zero
                                    if b_dot = '0' and
                                       b_int = 1 and
                                       b_mag = 0 then

                                        b_mag <= sw_digit;

                                    else

                                        b_mag <=
                                            b_mag * 10 + sw_digit;

                                        if b_dot = '0' then
                                            b_int <= b_int + 1;
                                        else
                                            b_frac <= b_frac + 1;
                                        end if;

                                    end if;

                                    if b_int = 0 and
                                       b_dot = '0' then
                                        b_int <= 1;
                                    end if;

                                    digit_armed <= '0';

                                end if;

                            end if;

                        end if;

                    end if;
                end if;

                held_reset <= '0';

            end if;

            ----------------------------------------
            -- BACKSPACE / DECIMAL / SIGN
            -- INPUT MODE: SW15 = 0
            ----------------------------------------

            if c_level = '0' and
               sw_level(15) = '0' then

                ----------------------------------
                -- BACKSPACE (SW10)
                ----------------------------------

                if sw_level(10) = '1' and
                   old_back = '0' then

                    if state = ENTER_A then

                        if a_dot = '1' and
                           a_frac = 0 then

                            -- Remove decimal point
                            a_dot <= '0';

                        elsif a_frac > 0 then

                            -- Remove fractional digit
                            a_mag <= a_mag / 10;
                            a_frac <= a_frac - 1;

                        elsif a_int > 0 then

                            -- Remove integer digit
                            a_mag <= a_mag / 10;
                            a_int <= a_int - 1;

                        end if;

                    elsif state = ENTER_B then

                        if b_dot = '1' and
                           b_frac = 0 then

                            b_dot <= '0';

                        elsif b_frac > 0 then

                            b_mag <= b_mag / 10;
                            b_frac <= b_frac - 1;

                        elsif b_int > 0 then

                            b_mag <= b_mag / 10;
                            b_int <= b_int - 1;

                        end if;

                    end if;

                end if;

                ----------------------------------
                -- DECIMAL POINT (SW11)
                ----------------------------------

                if sw_level(11) = '1' and
                   old_dot = '0' then

                    if state = ENTER_A and
                       a_dot = '0' then

                        a_dot <= '1';

                        -- Start .5 as 0.5
                        if a_int = 0 then
                            a_int <= 1;
                            a_mag <= 0;
                        end if;

                    elsif state = ENTER_B and
                          b_dot = '0' then

                        b_dot <= '1';

                        if b_int = 0 then
                            b_int <= 1;
                            b_mag <= 0;
                        end if;

                    end if;

                end if;

                ----------------------------------
                -- NEGATIVE SIGN TOGGLE (BTNL)
                ----------------------------------

                if l_level = '1' and
                   old_l = '0' then

                    if state = ENTER_A then
                        a_neg <= not a_neg;

                    elsif state = ENTER_B then
                        b_neg <= not b_neg;

                    end if;

                end if;

            end if;

            ----------------------------------------
            -- CALCULATE MODE: SW15 = 1
            ----------------------------------------

            if c_level = '0' and
               sw_level(15) = '1' and
               state = ENTER_B and
               b_int > 0 then

                if u_level = '1' and old_u = '0' then
                    chosen_op <= 0;
                    state <= PREPARE;

                elsif l_level = '1' and old_l = '0' then
                    chosen_op <= 1;
                    state <= PREPARE;

                elsif r_level = '1' and old_r = '0' then
                    chosen_op <= 2;
                    state <= PREPARE;

                elsif d_level = '1' and old_d = '0' then
                    chosen_op <= 3;
                    state <= PREPARE;

                end if;

            end if;

            ----------------------------------------
            -- PREPARE CALCULATION
            ----------------------------------------

            if state = PREPARE then

                va := a_scaled;
                vb := scale100(b_mag, b_frac);

                b_scaled <= vb;
                error_flag <= '0';

                neg_v := '0';
                vr := 0;

                case chosen_op is

                    --------------------------------
                    -- ADDITION
                    --------------------------------

                    when 0 =>

                        if a_neg = b_neg then

                            vr := va + vb;
                            neg_v := a_neg;

                        elsif va >= vb then

                            vr := va - vb;
                            neg_v := a_neg;

                        else

                            vr := vb - va;
                            neg_v := b_neg;

                        end if;

                    --------------------------------
                    -- SUBTRACTION
                    --------------------------------

                    when 1 =>

                        if a_neg /= b_neg then

                            vr := va + vb;
                            neg_v := a_neg;

                        elsif va >= vb then

                            vr := va - vb;
                            neg_v := a_neg;

                        else

                            vr := vb - va;
                            neg_v := not a_neg;

                        end if;

                    --------------------------------
                    -- MULTIPLY / DIVIDE SIGN
                    --------------------------------

                    when others =>

                        neg_v := a_neg xor b_neg;

                end case;

                result_negative <= neg_v;

                --------------------------------
                -- ADD / SUB RESULT
                --------------------------------

                if chosen_op = 0 or chosen_op = 1 then

                    if vr > 9999999 then

                        error_flag <= '1';
                        state <= RESULT_PAGE;

                    else

                        result_cents <= vr;

                        format_rest <= vr;
                        format_pos <= 6;

                        out_digits <= (others => 0);

                        state <= FORMAT_DECIMAL;

                    end if;

                --------------------------------
                -- MULTIPLY / DIVIDE
                --------------------------------

                else

                    if chosen_op = 3 and vb = 0 then

                        error_flag <= '1';
                        state <= RESULT_PAGE;

                    else

                        if chosen_op = 2 then

                            -- Product with rounding
                            temp_u := (others => '0');

                            temp_u(33 downto 0) :=
                                to_unsigned(va, 17) *
                                to_unsigned(vb, 17);

                            numerator_bits <=
                                resize(
                                    temp_u(33 downto 0) +
                                    to_unsigned(50, 34),
                                    34
                                );

                            denominator <= 100;

                        else

                            -- (A * 100) / B
                            numerator_bits <=
                                to_unsigned(va * 100, 34);

                            denominator <= vb;

                        end if;

                        quotient_r <= (others => '0');
                        remainder_r <= 0;
                        bit_index <= 33;

                        state <= DIVIDE_BITS;

                    end if;

                end if;

            end if;

            ----------------------------------------
            -- SEQUENTIAL BINARY DIVISION
            ----------------------------------------

            if state = DIVIDE_BITS then

                rem_next := remainder_r * 2;

                if numerator_bits(bit_index) = '1' then
                    rem_next := rem_next + 1;
                end if;

                quot_next := quotient_r;

                if rem_next >= denominator then

                    rem_next := rem_next - denominator;
                    quot_next(bit_index) := '1';

                end if;

                remainder_r <= rem_next;
                quotient_r <= quot_next;

                if bit_index = 0 then

                    -- Division rounding
                    if chosen_op = 3 and
                       rem_next * 2 >= denominator then

                        quot_next := quot_next + 1;

                    end if;

                    -- Display overflow
                    if quot_next > to_unsigned(9999999, 34) then

                        error_flag <= '1';
                        state <= RESULT_PAGE;

                    else

                        rr := to_integer(quot_next);

                        result_cents <= rr;
                        format_rest <= rr;

                        format_pos <= 6;
                        out_digits <= (others => 0);

                        state <= FORMAT_DECIMAL;

                    end if;

                else

                    bit_index <= bit_index - 1;

                end if;

            end if;

            ----------------------------------------
            -- RESULT DECIMAL FORMATTER
            ----------------------------------------

            if state = FORMAT_DECIMAL then

                if format_rest >= PLACES(format_pos) then

                    format_rest <=
                        format_rest - PLACES(format_pos);

                    out_digits(format_pos) <=
                        out_digits(format_pos) + 1;

                elsif format_pos = 0 then

                    state <= RESULT_PAGE;

                else

                    format_pos <= format_pos - 1;

                end if;

            end if;

        end if;
    end process;

    ----------------------------------------
    -- 7-SEGMENT DISPLAY CONTROLLER
    ----------------------------------------

    process(all)

        variable mag, ni, nf : integer;
        variable total, d : integer;

        variable dot_on : boolean;
        variable negative : boolean;
        variable leading : boolean;

    begin

        -- Start with blank display
        for i in 0 to 7 loop
            disp(i) <= "1111111";
        end loop;

        dp_bits <= (others => '1');

        mag := 0;
        ni := 0;
        nf := 0;
        total := 0;
        d := 0;

        dot_on := false;
        negative := false;
        leading := false;

        ----------------------------------
        -- DISPLAY INPUT A OR B
        ----------------------------------

        if state = ENTER_A or state = ENTER_B then

            if state = ENTER_A then

                mag := a_mag;
                ni := a_int;
                nf := a_frac;

                dot_on := (a_dot = '1');
                negative := (a_neg = '1');

            else

                mag := b_mag;
                ni := b_int;
                nf := b_frac;

                dot_on := (b_dot = '1');
                negative := (b_neg = '1');

            end if;

            ----------------------------------
            -- LIVE DIGIT PREVIEW
            ----------------------------------

            if sw_count = 1 and
               digit_armed = '1' and
               sw_level(15) = '0' then

                if (not dot_on and ni < 3) or
                   (dot_on and nf < 2) then

                    if not dot_on and
                       ni = 1 and
                       mag = 0 then

                        mag := sw_digit;

                    else

                        mag := mag * 10 + sw_digit;

                        if dot_on then
                            nf := nf + 1;
                        else
                            ni := ni + 1;
                        end if;

                    end if;

                    if ni = 0 then
                        ni := 1;
                    end if;

                end if;

            end if;

            ----------------------------------
            -- SHOW INPUT DIGITS
            ----------------------------------

            total := ni + nf;

            for i in 0 to 4 loop

                if i < total then

                    d := mag mod 10;
                    disp(i) <= seg7(d);
                    mag := mag / 10;

                end if;

            end loop;

            -- Place decimal point
            if dot_on then
                dp_bits(nf) <= '0';
            end if;

            -- Negative sign at AN7
            if negative then
                disp(7) <= seg7(10);
            end if;

            -- Multiple digit switches ON
            if sw_count > 1 then
                disp(6) <= seg7(11);
            end if;

        ----------------------------------
        -- DISPLAY RESULT
        ----------------------------------

        elsif state = RESULT_PAGE then

            if error_flag = '1' then

                -- Err
                disp(2) <= seg7(11);
                disp(1) <= seg7(12);
                disp(0) <= seg7(12);

            else

                -- Hide leading zeros
                for i in 6 downto 3 loop

                    if out_digits(i) /= 0 then
                        leading := true;
                    end if;

                    if leading then
                        disp(i) <= seg7(out_digits(i));
                    end if;

                end loop;

                -- Units and two decimals
                disp(2) <= seg7(out_digits(2));
                disp(1) <= seg7(out_digits(1));
                disp(0) <= seg7(out_digits(0));

                -- Decimal point after AN2
                dp_bits(2) <= '0';

                -- Negative sign
                if result_negative = '1' and
                   result_cents /= 0 then

                    disp(7) <= seg7(10);

                end if;

            end if;

        end if;

    end process;

    ----------------------------------------
    -- REFRESH COUNTER
    ----------------------------------------

    process(clk)
    begin
        if rising_edge(clk) then
            refresh <= refresh + 1;
        end if;
    end process;

    scan <= to_integer(refresh(16 downto 14));

    ----------------------------------------
    -- 7-SEGMENT MULTIPLEXING
    ----------------------------------------

    process(all)

        variable an_temp :
            std_logic_vector(7 downto 0);

    begin

        an_temp := (others => '1');
        an_temp(scan) := '0';

        AN <= an_temp;
        SEG <= disp(scan);
        DP <= dp_bits(scan);

    end process;

end architecture;
