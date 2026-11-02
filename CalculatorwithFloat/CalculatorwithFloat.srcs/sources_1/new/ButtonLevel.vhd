
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity ButtonLevel is
    generic (
        DEBOUNCE_CYCLES : positive := 500000
    );
    port (
        clk       : in std_logic;
        btn_in    : in std_logic;
        btn_level : out std_logic
    );
end entity;

architecture RTL of ButtonLevel is

    signal sync0, sync1, stable :
        std_logic := '0';

    signal count :
        natural range 0 to DEBOUNCE_CYCLES - 1 := 0;

begin

    process(clk)
    begin
        if rising_edge(clk) then

            sync0 <= btn_in;
            sync1 <= sync0;

            if sync1 = stable then
                count <= 0;

            elsif count = DEBOUNCE_CYCLES - 1 then
                stable <= sync1;
                count <= 0;

            else
                count <= count + 1;

            end if;

        end if;
    end process;

    btn_level <= stable;

end architecture;
