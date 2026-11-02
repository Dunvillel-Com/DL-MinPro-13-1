/*
Design for the DVL MinPro 13-1 CPU
MISC-like instruction set
13-bit, no native float


Structure:
5 registers; 2 for math and work (A, B), 2 only for work (C, D), 1 only for conditions (F)
Math/logic: +, -, *, &, |, !, <<, >>

1 output and 2 inputs for instructions:
out: address
inp1: instruction
inp2: data

Has a 20 slot stack

Can place interrupts to jump to places in the program. This saves the registers (to TA-TE), pushes
the PC to TPC, and jumps to the set location. There are 5 interrupts, and they are able to
be enabled or disabled via software at any time (I0f through I4f). The interrupts listen
to specific wires that are not configurable. The places they jump to are configurable, stored
in IJ0 through IJ4. You can toggle if the CPU is interruptable (IF_global), which is set to false when interrupted.
I0-I9 are readable as inputs, I0-I4 are used as interrupts.
Returning from an interrupt does not change the stack or global interrupt allow state!

Can output on 10 wires, O0 to O9 and input on 10 others, I0 to I9
Can also output characters to Char Out using a custom protocol - this sends the char to an external display device, like an Arduino with a text display.



ISA:
// Basic register stuff
 1: Set A to literal inp2
 2: Set B to literal inp2
 3: Set C to literal inp2
 4: Set D to literal inp2
 5: Set F to 0 (false)
 6: Set F to 1 (true)
 7: Copy A to B
 8: Copy B to A
 9: Copy C to A
10: Copy C to B
11: Copy A to C
12: Copy B to C
13: Copy D to A
14: Copy D to B
15: Copy A to D
16: Copy B to D
17: Copy A to F
18: Copy B to F
19: Copy F to A
20: Copy F to B
// Jumps and stack
21: Jump to inp2
22: Jump to inp2 if F
23: Jump to inp2 if not F
24: Make next call   (sets a one-time flag: the next jump will push to the stack if it jumps)
25: Push inp2 to Stack
26: Jump to and pop Stack
27: Jump to and pop Stack if F
28: Jump to and pop Stack if not F
// Math and logic
29: Set A to A + B
30: Set B to B + A
31: Set A to A - B
32: Set A to B - A
33: Set A to A * B
34: Set A to A + inp2
35: Set A to A - inp2
36: Set A to inp2 - A
37: Set A to A * inp2
38: Set A to A | B
39: Set A to A & B
40: Set A to !A
41: Set A to A << B
42: Set A to A >> B
43: Set A to A << inp2
44: Set A to A >> inp2
45: Compare A == B set to F
46: Compare A > B set to F
47: Compare A < B set to F
48: Compare A >= B set to F
49: Compare A <= B set to F
50: Compare A != B set to F
51: Compare A == inp2 set to F
52: Compare A > inp2 set to F
53: Compare A < inp2 set to F
54: Compare A >= inp2 set to F
55: Compare A <= inp2 set to F
56: Compare A != inp2 set to F
// RAM access
57: Set A to RAM[inp2]
58: Set B to RAM[inp2]
59: Set RAM[inp2] to A
60: Set RAM[inp2] to B
61: Set A to RAM[B]
62: Set RAM[B] to A
// Interrupts
63: Set interrupt location IJ0 to inp2
64: Set interrupt location IJ1 to inp2
65: Set interrupt location IJ2 to inp2
66: Set interrupt location IJ3 to inp2
67: Set interrupt location IJ4 to inp2
68: Set interrupt flag I0f to inp2
69: Set interrupt flag I1f to inp2
70: Set interrupt flag I2f to inp2
71: Set interrupt flag I3f to inp2
72: Set interrupt flag I4f to inp2
73: Return from interrupt  (restores registers, stack is untouched! Does not change global interrupt allowance)
74: Set if interruptable to inp2
// Input/Output - O[#] refers to O0-O9, I[#] is I0-I9
75: Set O[inp2] to A
76: Set O[inp2] to B
77: Set O[B] to A
78: Set A to I[inp2]
79: Set B to I[inp2]
80: Set A to I[B]
81: Send A to char output
82: Send B to char output
// Others
83: No operation
84: Stop clock
*/



// ----------------------------------------------
// ROM/RAM stuff
// ----------------------------------------------

module rom (
        input logic clk,
        input logic [12:0] addr,
        output logic [12:0] inst,
        output logic [12:0] data
    );

    logic [25:0] memory[0:8191];

    initial $readmemh("prog.hex", memory);

    always_ff @(posedge clk)
        {inst, data} <= memory[addr];
endmodule

module ram (
        input logic clk,
        input logic [12:0] addr,
        input logic write,
        input logic [12:0] wData,
        output logic [12:0] data
    );

    logic [12:0] ram[0:8191];

    always_ff @(posedge clk) begin
        if (write) ram[addr] <= wData;
        data <= ram[addr];
    end
endmodule






module dvl_minpro_cpu (
    input logic clk,
    input logic [9:0] I,            // 10 input wires
    input char_busy,
    input reset,
    output logic [9:0] O,           // 10 output wires
    output logic [8:0] char_data,   // custom char protocol
    output logic char_strobe
);



// ----------------------------------------------
// Declarations of common stuff
// ----------------------------------------------

logic [12:0] nextPC;

logic load_wait;



// ----------------------------------------------
// Registers 
// ----------------------------------------------

logic [12:0] A;
logic [12:0] B;
logic [12:0] C;
logic [12:0] D;
logic F;



// ----------------------------------------------
// Stack
// ----------------------------------------------

logic [12:0] stack [0:19];

logic [5:0] SC;

logic call;



// ----------------------------------------------
// Operational
// ----------------------------------------------

logic [12:0] PC;


logic [12:0] instr;
logic [12:0] inp2;

rom program_rom(.clk(clk), .addr(reset ? 13'd0 : nextPC), .inst(instr), .data(inp2));


logic [12:0] rAddr;
logic [12:0] rRead;
logic rWrite;
logic [12:0] rwData;

ram program_ram(.clk(clk), .addr(rAddr), .write(rWrite), .wData(rwData), .data(rRead));



// ----------------------------------------------
// Char output
// ----------------------------------------------

logic out;

logic handshake;

logic stall;




// ----------------------------------------------
// Interrupts
// ----------------------------------------------

// Interrupt jump locations
logic [12:0] IJ[0:4];

// Interrupt enabled flags
logic IF[0:4];

// Store these for return
logic [12:0] TA;
logic [12:0] TB;
logic [12:0] TC;
logic [12:0] TD;
logic TF;

logic [12:0] TPC;

logic IF_global;




// ----------------------------------------------
// Interrupt handler
// ----------------------------------------------

logic take_interrupt;
logic [2:0] active_int_id;

logic [4:0] stage1;
logic [4:0] synced;

logic [4:0] syncBuffer;

always_comb begin
    take_interrupt = 0;
    active_int_id = 0;

    if (IF_global) begin
        if (IF[0] && syncBuffer[0] && !synced[0]) begin
            take_interrupt = 1; active_int_id = 3'd0;
        end else if (IF[1] && syncBuffer[1] && !synced[1]) begin
            take_interrupt = 1; active_int_id = 3'd1;
        end else if (IF[2] && syncBuffer[2] && !synced[2]) begin
            take_interrupt = 1; active_int_id = 3'd2;
        end else if (IF[3] && syncBuffer[3] && !synced[3]) begin
            take_interrupt = 1; active_int_id = 3'd3;
        end else if (IF[4] && syncBuffer[4] && !synced[4]) begin
            take_interrupt = 1; active_int_id = 3'd4;
        end
    end
end

always_ff @(posedge clk) begin
    stage1 <= {I[4], I[3], I[2], I[1], I[0]};
    syncBuffer <= stage1;
    synced <= syncBuffer;
end




// ----------------------------------------------
// Instruction decoder
// ----------------------------------------------

logic pauseForCOut;

always_comb begin

    rAddr = 0;
    rWrite = 0;
    rwData = 0;

    pauseForCOut = handshake | out;

    stall = char_busy | pauseForCOut;

    nextPC = stall ? PC : PC + 1;

    if (take_interrupt) begin
        nextPC = IJ[active_int_id];
    end else if (!stall) begin
        case(instr)

            13'd21: begin
                nextPC = inp2;
            end

            13'd22: begin
                if (F) begin
                    nextPC = inp2;
                end
            end

            13'd23: begin
                if (~F) begin
                    nextPC = inp2;
                end
            end

            13'd26: begin
                if (SC > 0)
                    nextPC = stack[SC - 1];
            end

            13'd27: begin
                if (F) begin
                    if (SC > 0)
                        nextPC = stack[SC - 1];
                end
            end

            13'd28: begin
                if (~F) begin
                    if (SC > 0)
                        nextPC = stack[SC - 1];
                end
            end

            13'd57: begin
                rAddr = inp2;
                if (!load_wait) nextPC = PC;
            end

            13'd58: begin
                rAddr = inp2;
                if (!load_wait) nextPC = PC;
            end

            13'd59: begin
                rWrite = 1;
                rAddr = inp2;
                rwData = A;
            end

            13'd60: begin
                rWrite = 1;
                rAddr = inp2;
                rwData = B;
            end
            
            13'd61: begin
                rAddr = B;
                if (!load_wait) nextPC = PC;
            end

            13'd62: begin
                rWrite = 1;
                rAddr = B;
                rwData = A;
            end

            13'd73: begin
                nextPC = TPC;
            end

            13'd84: begin
                nextPC = PC;
            end

            default: ;//do nothing
        endcase
    end
end

always_ff @(posedge clk) begin
    if (reset) begin
        PC <= 0; SC <= 0; call <= 0; IF_global <= 0; F <= 0;
        A <= 0; B <= 0; C <= 0; D <= 0;
        O <= 0; char_strobe <= 0; handshake <= 0; out <= 0;
        for (int i = 0; i < 5; i++) begin
            IF[i] <= 0; IJ[i] <= 0;
        end
        load_wait <= 0;
    end else if (take_interrupt) begin
        IF_global <= 0;
        TA <= A; TB <= B; TC <= C; TD <= D; TF <= F;
        TPC <= PC;
        PC <= IJ[active_int_id];
        load_wait <= 0;
    end else if (char_busy) begin
        char_strobe <= 0;
        out <= 0;
        handshake <= 0;
    end else begin
        char_strobe <= handshake && !out;
        out <= 0;
        if (!pauseForCOut) begin
            PC <= nextPC;
            
            case(instr)
                13'd1: begin
                    A <= inp2;
                end

                13'd2: begin
                    B <= inp2;
                end

                13'd3: begin
                    C <= inp2;
                end

                13'd4: begin
                    D <= inp2;
                end

                13'd5: begin
                    F <= 0;
                end

                13'd6: begin
                    F <= 1;
                end

                13'd7: begin
                    B <= A;
                end

                13'd8: begin
                    A <= B;
                end

                13'd9: begin
                    A <= C;
                end

                13'd10: begin
                    B <= C;
                end

                13'd11: begin
                    C <= A;
                end

                13'd12: begin
                    C <= B;
                end

                13'd13: begin
                    A <= D;
                end

                13'd14: begin
                    B <= D;
                end

                13'd15: begin
                    D <= A;
                end

                13'd16: begin
                    D <= B;
                end

                13'd17: begin
                    F <= A != 0;
                end

                13'd18: begin
                    F <= B != 0;
                end

                13'd19: begin
                    A <= F;
                end

                13'd20: begin
                    B <= F;
                end

                13'd21: begin
                    if (call) begin
                        if (SC < 20) begin
                            SC <= SC + 1;
                            stack[SC] <= PC + 1;
                        end
                        call <= 0;
                    end
                end

                13'd22: begin
                    if (F) begin
                        if (call) begin
                            if (SC < 20) begin
                                SC <= SC + 1;
                                stack[SC] <= PC + 1;
                            end
                        end
                    end
                    call <= 0;
                end

                13'd23: begin
                    if (~F) begin
                        if (call) begin
                            if (SC < 20) begin
                                SC <= SC + 1;
                                stack[SC] <= PC + 1;
                            end
                        end
                    end
                    call <= 0;
                end

                13'd24: begin
                    call <= 1;
                end
                
                13'd25: begin
                    if (SC < 20) begin
                        SC <= SC + 1;
                        stack[SC] <= inp2;
                    end
                end

                13'd26: begin
                    if (SC > 0) begin
                        SC <= SC - 1;
                    end
                end

                13'd27: begin
                    if (F) begin
                        if (SC > 0) begin
                            SC <= SC - 1;
                        end
                    end
                end

                13'd28: begin
                    if (~F) begin
                        if (SC > 0) begin
                            SC <= SC - 1;
                        end
                    end
                end

                13'd29: begin
                    A <= A + B;
                end

                13'd30: begin
                    B <= B + A;
                end

                13'd31: begin
                    A <= A - B;
                end

                13'd32: begin
                    A <= B - A;
                end

                13'd33: begin
                    A <= A * B;
                end

                13'd34: begin
                    A <= A + inp2;
                end

                13'd35: begin
                    A <= A - inp2;
                end

                13'd36: begin
                    A <= inp2 - A;
                end

                13'd37: begin
                    A <= A * inp2;
                end

                13'd38: begin
                    A <= A | B;
                end

                13'd39: begin
                    A <= A & B;
                end

                13'd40: begin
                    A <= ~A;
                end

                13'd41: begin
                    A <= A << B;
                end

                13'd42: begin
                    A <= A >> B;
                end

                13'd43: begin
                    A <= A << inp2;
                end

                13'd44: begin
                    A <= A >> inp2;
                end

                13'd45: begin
                    F <= A == B;
                end

                13'd46: begin
                    F <= A > B;
                end

                13'd47: begin
                    F <= A < B;
                end

                13'd48: begin
                    F <= A >= B;
                end

                13'd49: begin
                    F <= A <= B;
                end

                13'd50: begin
                    F <= A != B;
                end

                13'd51: begin
                    F <= A == inp2;
                end

                13'd52: begin
                    F <= A > inp2;
                end

                13'd53: begin
                    F <= A < inp2;
                end

                13'd54: begin
                    F <= A >= inp2;
                end

                13'd55: begin
                    F <= A <= inp2;
                end

                13'd56: begin
                    F <= A != inp2;
                end

                13'd57: begin
                    if (load_wait) begin 
                        A <= rRead; 
                        load_wait <= 0; 
                    end else load_wait <= 1;
                end

                13'd58: begin
                    if (load_wait) begin 
                        B <= rRead; 
                        load_wait <= 0; 
                    end else load_wait <= 1;
                end

                13'd61: begin
                    if (load_wait) begin 
                        A <= rRead; 
                        load_wait <= 0; 
                    end else load_wait <= 1;
                end

                13'd63: begin
                    IJ[0] <= inp2;
                end

                13'd64: begin
                    IJ[1] <= inp2;
                end

                13'd65: begin
                    IJ[2] <= inp2;
                end

                13'd66: begin
                    IJ[3] <= inp2;
                end

                13'd67: begin
                    IJ[4] <= inp2;
                end

                13'd68: begin
                    IF[0] <= inp2 != 0;
                end

                13'd69: begin
                    IF[1] <= inp2 != 0;
                end

                13'd70: begin
                    IF[2] <= inp2 != 0;
                end

                13'd71: begin
                    IF[3] <= inp2 != 0;
                end

                13'd72: begin
                    IF[4] <= inp2 != 0;
                end

                13'd73: begin
                    A <= TA; B <= TB; C <= TC; D <= TD; F <= TF;
                end

                13'd74: begin
                    IF_global <= inp2 != 0;
                end

                13'd75: begin
                    O[inp2[3:0]] <= A[9:0] != 0;
                end

                13'd76: begin
                    O[inp2[3:0]] <= B[9:0] != 0;
                end

                13'd77: begin
                    O[B[3:0]] <= A[9:0] != 0;
                end

                13'd78: begin
                    A <= {12'b0, I[inp2[3:0]]};
                end

                13'd79: begin
                    B <= {12'b0, I[inp2[3:0]]};
                end

                13'd80: begin
                    A <= {12'b0, I[B[3:0]]};
                end

                13'd81: begin
                    char_data <= A[8:0];
                    out <= 1;
                    handshake <= 1;
                end

                13'd82: begin
                    char_data <= B[8:0];
                    out <= 1;
                    handshake <= 1;
                end

                default: ;//do nothing
            endcase
        end
    end
end








endmodule