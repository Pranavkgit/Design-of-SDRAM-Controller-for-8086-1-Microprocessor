`timescale 1ns / 1ps

//Assuming the input clk is phase locked to 100MHz ~ SDRAM_CLK

module SDRAM_Top(
        
        input wire clk,
        input wire rstn,
        
        input wire mrdn,
        input wire mwrdn,
        output wire read,
        output wire write,
        
        inout [15:0] data,
        input [19:0] Address,     
        input BHEn,
        inout [3:0] DQ,
        output reg DQMn,
        output reg SDRAM_CLK,
        output reg CKE,
        output reg rdyn,
        output csn,
        output rasn,
        output casn,
        output wen,
        output reg [11:0] SD_Add,
        output reg [2:0]SD_Bank
    );
    
    reg [0:23] sdram_nibbleadd;
    reg [1:0] BE;
    
    logic mode;
    reg [3:0] State;
    reg [2:0] CMD; 
    
    parameter int Load_Value   = 10000;   //100MHz to wait 100us
    parameter int Load_Refresh = 15625;
    
    logic wait_done;
    logic PLL;
    reg [31:0] count;
    reg [31:0] counter2;
    
    
    //------------Commands for each state RASn,CASn,WEn------------
    parameter NOP       = 3'b111;
    parameter PRE_CHARGE  = 3'b010;
    parameter AUTO1       = 3'b001;
    parameter AUTO2       = 3'b001;
    parameter LOAD        = 3'b000;
    parameter RD          = 3'b101;
    parameter WR          = 3'b100;
    parameter ACT         = 3'b001;
    
    
    //-----------States Defined------------
    parameter wait_clk    = 4'd0;
    parameter wait_100us = 4'd1;
    parameter pc = 4'd2;
    parameter auto_ref1 = 4'd3;
    parameter auto_ref2  = 4'd4;
    parameter LMR  = 4'd5;
    parameter Idle = 4'd6;
    parameter Refresh = 4'd7;
    parameter ACT_Read = 4'd8;
    parameter ACT_Write = 4'd9;
    parameter Read = 4'd10;
    parameter Write = 4'd11;
    parameter dataread = 4'd12;
    parameter datawrite=4'd13;
    parameter write_wait = 4'd14;
       
    logic done;
    reg [3:0] wait_state;
    parameter trp = 2; 
    parameter trfc = 7;
    parameter tmrcd = 2;
   //------------Initialization state machine.---------------
    always_ff @(negedge(SDRAM_CLK))
    begin
        if(!rstn)
        begin        
            wait_state <= 1;
            State <= wait_clk;     
        end
        assign done = ((CKE==1) && (wait_done == 1));
        if(State == wait_100us && done) State<= pc;
        if(State== wait_100us &&!done) State<= wait_100us;
        case(State)
            wait_clk:
            begin
             CKE <= 0;  
             CMD<=NOP; 
             count <= Load_Value;   
             wait_done <= 0; 
             PLL<=1;
             if(PLL) State<= wait_100us;
             else State <= wait_clk;
            end
            wait_100us:
            begin
                CKE <=1;
                CMD<=NOP;
                if(count > 0)      count <= count-1;
                else
                begin
                    count <=Load_Value;
                    wait_done <= 1;
                end
            end
            pc:
            begin
                if(wait_state == 1) CMD<=PRE_CHARGE;
                CKE<=1;
                if(wait_state<=trp) //should happen in next state.
                begin
                    if(wait_state != 1)   CMD <= NOP;
                    if(wait_state != 1 && wait_state == trp)   State<=auto_ref1;
                    wait_state <= wait_state + 1;
                    if(State !=pc) wait_state<=1;
                 end
            end
            auto_ref1,auto_ref2:
            begin
             CKE<=1;
            if(State == auto_ref1 && wait_state ==1)    CMD<= AUTO1;
            if(State == auto_ref2 && wait_state ==1)      CMD<=AUTO2; 
            if((State == auto_ref1 || State == auto_ref2) && wait_state<=trfc)
            begin
                if(wait_state != 1)    CMD <= NOP;
                if(State == auto_ref1 && wait_state!=1 && wait_state == trfc)  State <=auto_ref2;
                wait_state <= wait_state + 1;
                if(State == auto_ref2 && wait_state!=1 && wait_state == trfc)  State <=LMR;
                if(State!=auto_ref1 || State!=auto_ref2) wait_state<=1;
            end
            end
            LMR:
            begin
            CKE<=1;
            CMD<=LOAD;
            if(wait_state<=tmrcd)
            begin
                if(wait_state!=1)    CMD <= NOP;
                if(wait_state!=1 && wait_state == tmrcd) 
                begin
                    State<=Idle;
                    counter2 <= Load_Refresh;
                 end
                wait_state <= wait_state +1;
                if(State!=LMR)  wait_state <=1;
            end    
            end
         endcase
    end
    
    //---------2nd state Machine after idle.-------------
    reg Refresh_req;
    parameter trcd = 2;
    parameter tcl = 2;
     
    reg [15:0] store_data;
    parameter BL = 4;
    parameter twr=2;
    
    
    reg [3:0] DQ_out;
    assign DQ = (State == datawrite) ? DQ_out : 4'bzzzz;
    
    reg [15:0] data_in;
    assign data = (State == dataread && wait_state>BL) ? data_in : 16'bzzzzzzzzzzzzzzzz;
    
    //---------Clock crossing for read and write signals------
    reg mrdn_ff1;
    reg mrdn_ff2;
   always_ff@(posedge(SDRAM_CLK))   mrdn_ff1<=mrdn; 
   always_ff@(posedge(SDRAM_CLK))   mrdn_ff2<=mrdn_ff1;
   assign read = !mrdn_ff2;
  
   reg mwrdn_ff1;
   reg mwrdn_ff2;
   always_ff@(posedge(SDRAM_CLK))   mwrdn_ff1<=mwrdn; 
   always_ff@(posedge(SDRAM_CLK))   mwrdn_ff2<=mwrdn_ff1;
   assign write = !mwrdn_ff2;
   
    always_ff @(negedge(SDRAM_CLK))
    begin
    if(read) State<=ACT_Read;
    if(write) State<=ACT_Write;
    case(State)
        Idle:
        begin
            rdyn<=0;
            CKE<=1;
            if(Load_Refresh>0)   counter2 <= counter2 - 1;
            else
                begin
                    State <= Refresh;
                    Refresh_req <= 1;
                    rdyn <=1;
                end
          end
//         ------- Refresh State --------
          Refresh:
          begin
          CKE<=1;
            if(Refresh_req==1 && wait_state<trfc) CMD<=NOP;      
            wait_state <= wait_state+1;
            if(Refresh_req == 1 && wait_state == trfc)
            begin
                rdyn <=0;
                State<=Idle; 
                wait_state <=1;
                Refresh_req <=0;
                counter2 <= Load_Refresh;               
            end
          end
//   --------read state---------
    ACT_Read:
    begin
    rdyn<=1;
    if(wait_state <= trcd) //2
    begin
        if(wait_state ==1) CMD <=ACT;
        else           CMD <=NOP;
          wait_state <= wait_state +1;
          if(wait_state >trcd) 
          begin
            wait_state<=1;
            State<= Read;
            end
    end
    end
     Read:
     begin
             CMD <= RD;
             if(wait_state <=tcl) 
                if(wait_state !=1 ) CMD<=NOP;
             wait_state <=wait_state +1;
             if(wait_state > tcl)
             begin
                wait_state <= wait_state +1;
                State <=dataread;
             end         
     end
     dataread :
     begin
        if(wait_state <=BL)     
        begin
            if(wait_state <3) rdyn<=1;
            else rdyn <=0;
            if(wait_state == 1) 
                if(!DQMn)           store_data[3:0] <= DQ;
            else if (wait_state==2) 
                if(!DQMn)           store_data[7:4]<= DQ;
            else if (wait_state==3)
                if(!DQMn)           store_data[11:8]<= DQ;
            else if (wait_state==4)
                if(!DQMn)           store_data[15:12]<= DQ;
            State <=dataread;
            wait_state <= wait_state+1;
            if(wait_state<=BL) CMD<=NOP;
        end
       else if(wait_state > BL) 
       begin
       data_in<=store_data;
        wait_state <=1;
        State <=Idle;
        end
       end
 
    // -------- write state -------------
    ACT_Write:
    begin
    rdyn<=1;
    if(wait_state <= trcd) //2
    begin
        if(wait_state ==1) CMD <=ACT;
        else           CMD <=NOP;
          wait_state <= wait_state +1;
          if(wait_state >trcd) 
          begin
            wait_state<=1;
            State<= Write;
            end
    end
    end
     Write:
     begin
             CMD <= WR;
             State <=datawrite;        
     end
     datawrite :
     begin
        if(wait_state <=BL)    
        begin
            rdyn<=1;
            if (wait_state==1)
                if(!DQMn)              DQ_out[3:0]<=data[3:0];
            else if (wait_state==2)
                if(!DQMn)              DQ_out[3:0]<=data[7:4];
            else if (wait_state==3)
                if(!DQMn)              DQ_out[3:0]<=data[11:8];
            else if (wait_state==4)
                if(!DQMn)              DQ_out[3:0]<=data[15:12];
            State <=datawrite;
            wait_state <= wait_state+1;
            if(wait_state<=BL) CMD<=NOP;
        end
        if(wait_state > BL) 
            begin
                wait_state<=1;
                State <= write_wait;
            end
        end
       write_wait:
       begin
            if(wait_state <= twr)
                if(wait_state == 1) rdyn<=0;
                CMD<=NOP;
            wait_state <=wait_state+1; 
            if(wait_state > twr) 
            begin
                wait_state <= 1;
                State <=Idle;
             end
       end
       endcase
    end
//------ Output as a function of state -------------
always @ (*)
begin
    case(State)
        pc,auto_ref1,auto_ref2:
        begin
            SD_Add<=9'bzzzzzzzzz;
            SD_Add[10]<= 1'b1; //Autoprecharge
            SD_Add[9]<=1'b0;
            SD_Add[11]<=1'b0;
        end
        LMR:
        begin
            SD_Add[11:0] <= 12'b000000100010;
        end
        ACT_Read,ACT_Write:
        begin
            sdram_nibbleadd = {4'b0000, Address[19:10], Address[9:0]};
            SD_Add[11:0] <= sdram_nibbleadd[21:10]; //Row address
            SD_Bank[1:0] <= sdram_nibbleadd[23:22];
            BE = {Address[0],BHEn};
        end
        Read,Write:
        begin
            SD_Add[9:0]<=sdram_nibbleadd[9:0]; //Column address
            SD_Add[10]<= 1'b1; //Autoprecharge.
            SD_Add[11]<=1'b0;
            if(wait_state==1) DQMn<= BE[0];
            if(wait_state==2) DQMn<= BE[0];
            if(wait_state==3) DQMn<= BE[1];
            if(wait_state==4) DQMn<= BE[1];
        end
      endcase
end    
 
//-----------Outputs as a function of command---------------

reg chip_select;
reg write_enablen;
reg Row_ASn;
reg Col_ASn;

assign csn  = chip_select;
assign wen  = write_enablen;
assign rasn = Row_ASn;
assign casn = Col_ASn; 

always @ (*)
begin
    case(CMD)
        NOP:
        begin
            chip_select <= 1'b0;
            write_enablen <=1'b1;
            Row_ASn<=1'b1;
            Col_ASn<=1'b1;
        end
        PRE_CHARGE:
        begin
            chip_select <= 1'b0;
            write_enablen <=1'b0;
            Row_ASn<=1'b0;
            Col_ASn<=1'b1;
        end
        AUTO1:
        begin
            chip_select <= 1'b0;
            write_enablen <=1'b1;
            Row_ASn<=1'b0;
            Col_ASn<=1'b0;
        end
        AUTO2:
        begin
            chip_select <= 1'b0;
            write_enablen <=1'b1;
            Row_ASn<=1'b0;
            Col_ASn<=1'b0;
        end
        LOAD:
        begin
            chip_select <= 1'b0;
            write_enablen <=1'b0;
            Row_ASn<=1'b0;
            Col_ASn<=1'b0;
        end
       ACT:
          begin
            chip_select <= 1'b0;
            write_enablen <=1'b1;
            Row_ASn<=1'b0;
            Col_ASn<=1'b1;
        end
        Read:
         begin
            chip_select <= 1'b0;
            write_enablen <=1'b1;
            Row_ASn<=1'b1;
            Col_ASn<=1'b0;
        end
        Write:
         begin
            chip_select <= 1'b0;
            write_enablen <=1'b0;
            Row_ASn<=1'b1;
            Col_ASn<=1'b0;
        end
   endcase
 end
   
endmodule
