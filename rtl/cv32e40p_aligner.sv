// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

////////////////////////////////////////////////////////////////////////////////
// Engineer:       Pasquale Davide Schiavone - pschiavo@iis.ee.ethz.ch        //
//                                                                            //
// Additional contributions by:                                               //
//                 Igor Loi - igor.loi@greenwaves-technologies.com            //
//                                                                            //
// Design Name:    Instrctuon Aligner                                         //
// Project Name:   RI5CY                                                      //
// Language:       SystemVerilog                                              //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

module cv32e40p_aligner
(
  input  logic           clk,
  input  logic           rst_n,

  input  logic           fetch_valid_i,
  output logic           raw_instr_hold_o, //prevents overwriting the fethced instruction

  input  logic           id_valid_i,

  input  logic [31:0]    fetch_rdata_i,
  output logic [31:0]    instr_aligned_o,
  output logic           instr_valid_o,

  input  logic [31:0]    branch_addr_i,
  input  logic           branch_i,         // Asserted if we are branching/jumping now
  input  logic           branch_is_jump_i, // We are branching because of a JAL/JALR in ID

  input  logic [31:0]    hwlp_addr_i,
  input  logic           hwlp_update_pc_i,

  output logic [31:0]    pc_o,
  output logic [31:0]    pc_next_o,
  input  logic           hold_state_i      //prevent updating the PC during flushing instructions
);

  enum logic [2:0]  {ALIGNED32, MISALIGNED32, MISALIGNED16, BRANCH_MISALIGNED, WAIT_VALID_BRANCH} state, next_state;

  logic [15:0]       r_instr_h, r_instr_l;
  logic [31:0]       branch_addr_q;
  logic              instr_valid_q;
  logic [31:0]       pc_q, pc_n;
  logic              update_state;
  logic [31:0]       pc_plus4, pc_plus2;
  logic              raw_instr_hold_q;

  assign pc_o      = pc_q;
  assign pc_next_o = pc_n;

  assign pc_plus2  = pc_q + 2;
  assign pc_plus4  = pc_q + 4;

  always_ff @(posedge clk or negedge rst_n)
  begin : proc_SEQ_FSM
    if(~rst_n) begin
       state               <= ALIGNED32;
       r_instr_h        <= '0;
       r_instr_l        <= '0;
       branch_addr_q    <= '0;
       pc_q             <= '0;
       instr_valid_q    <= 1'b0;
       raw_instr_hold_q <= 1'b0;
    end else begin
        if(update_state) begin
          pc_q      <= pc_n;
          state     <= next_state;
          r_instr_h <= fetch_rdata_i[31:16];
          raw_instr_hold_q <= raw_instr_hold_o;
          // Save the whole instruction when a Jump occurs during a stall
          if (branch_i && branch_is_jump_i && !id_valid_i) begin
              r_instr_h     <= instr_aligned_o[31:16]; // Recycle r_instr_h to save the higher part of the JUMP instruction
              r_instr_l     <= instr_aligned_o[15:0];  // Store the lower part of the JUMP instruction
              instr_valid_q <= instr_valid_o;  // Maybe if we are here "instr_valid_o" is '1'
              branch_addr_q <= branch_addr_i;  // Save the JUMP target address to keep pc_n up to date during the stall
          end
        end
    end
  end

  always_comb
  begin

    //default outputs
    pc_n             = pc_q;
    instr_valid_o    = fetch_valid_i;
    instr_aligned_o  = fetch_rdata_i;
    raw_instr_hold_o = 1'b0;
    update_state     = 1'b0;
    next_state       = state;


    case(state)
      ALIGNED32:
      begin
            if(fetch_rdata_i[1:0] == 2'b11) begin
                /*
                  Before we fetched a 32bit aligned instruction
                  Therefore, now the address is aligned too and it is 32bits
                */
                next_state       = ALIGNED32;
                pc_n             = pc_plus4;
                instr_aligned_o  = fetch_rdata_i;
                //gate id_valid with fetch_valid as the next state should be evaluated only if mem content is valid
                update_state     = fetch_valid_i & id_valid_i & !hold_state_i;
                if(hwlp_update_pc_i)
                  pc_n = hwlp_addr_i;
            end else begin
                /*
                  Before we fetched a 32bit aligned instruction
                  Therefore, now the address is aligned too and it is 16bits
                */
                next_state       = MISALIGNED32;
                pc_n             = pc_plus2;
                instr_aligned_o  = fetch_rdata_i; //only the first 16b are used
                //gate id_valid with fetch_valid as the next state should be evaluated only if mem content is valid
                update_state     = fetch_valid_i & id_valid_i & !hold_state_i;
            end
      end


      MISALIGNED32:
      begin
            if(r_instr_h[1:0] == 2'b11) begin
                /*
                  Before we fetched a 32bit misaligned instruction
                  So now the beginning of the next instruction is the stored one
                  The istruction is 32bits so it is misaligned again
                */
                next_state       = MISALIGNED32;
                pc_n             = pc_plus4;
                instr_aligned_o  = {fetch_rdata_i[15:0],r_instr_h[15:0]};
                //gate id_valid with fetch_valid as the next state should be evaluated only if mem content is valid
                update_state     = fetch_valid_i & id_valid_i & !hold_state_i;
            end else begin
                /*
                  Before we fetched a 32bit misaligned instruction
                  So now the beginning of the next instruction is the stored one
                  The istruction is 16bits misaligned
                */
                instr_aligned_o  = {fetch_rdata_i[31:16],r_instr_h[15:0]};//only the first 16b are used
                next_state       = MISALIGNED16;
                instr_valid_o    = 1'b1;
                pc_n             = pc_plus2;
                //we cannot overwrite the 32bit instruction just fetched
                //so tell the IF stage to stall, the coming instruction goes to the FIFO
                raw_instr_hold_o = fetch_valid_i;
                //not need to gate id_valid with fetch_valid as the next state depends only on r_instr_h
                update_state     = id_valid_i & !hold_state_i;
            end
      end


      MISALIGNED16:
      begin
            //this is 1 as we holded the value before with raw_instr_hold_o
            instr_valid_o    = raw_instr_hold_q || fetch_valid_i;
            if(fetch_rdata_i[1:0] == 2'b11) begin
                /*
                  Before we fetched a 16bit misaligned instruction
                  So now the beginning of the next instruction is the new one
                  The istruction is 32bits so it is aligned
                */
                next_state       = ALIGNED32;
                pc_n             = pc_plus4;
                instr_aligned_o  = fetch_rdata_i;
                //no gate id_valid with fetch_valid as the next state sdepends only on mem content that has be held the previous cycle with raw_instr_hold_o
                update_state     = (raw_instr_hold_q | fetch_valid_i) & id_valid_i & !hold_state_i;
            end else begin
                /*
                  Before we fetched a 16bit misaligned  instruction
                  So now the beginning of the next instruction is the new one
                  The istruction is 16bit aligned
                */
                next_state       = MISALIGNED32;
                pc_n             = pc_plus2;
                instr_aligned_o  = fetch_rdata_i;//only the first 16b are used
                //no gate id_valid with fetch_valid as the next state sdepends only on mem content that has be held the previous cycle with raw_instr_hold_o
                update_state     = (raw_instr_hold_q | fetch_valid_i) & id_valid_i & !hold_state_i;
            end
      end


      BRANCH_MISALIGNED:
      begin
            //we jumped to a misaligned location, so now we received {TARGET, XXXX}
            if(fetch_rdata_i[17:16] == 2'b11) begin
                /*
                  We jumped to a misaligned location that contains 32bits instruction
                */
                next_state       = MISALIGNED32;
                instr_valid_o    = 1'b0;
                pc_n             = pc_q;
                instr_aligned_o  = fetch_rdata_i;
                //gate id_valid with fetch_valid as the next state should be evaluated only if mem content is valid
                update_state     = fetch_valid_i & id_valid_i & !hold_state_i;
            end else begin
                /*
                  We jumped to a misaligned location that contains 16bits instruction, as we consumed the whole word, we can preted to start again from ALIGNED32
                */
              next_state       = ALIGNED32;
              pc_n             = pc_plus2;
              instr_aligned_o  = {fetch_rdata_i[31:16],fetch_rdata_i[31:16]};//only the first 16b are used
              //gate id_valid with fetch_valid as the next state should be evaluated only if mem content is valid
              update_state     = fetch_valid_i & id_valid_i & !hold_state_i;
            end
      end


      // The instruction that was in ID when the "branch" happened is stuck in ID
      // We wait for the ID valid
      WAIT_VALID_BRANCH:
      begin
            next_state       = branch_addr_q[1] ? BRANCH_MISALIGNED : ALIGNED32;
            pc_n             = branch_addr_q;
            instr_aligned_o  = {r_instr_h, r_instr_l};
            update_state     = id_valid_i;
            instr_valid_o    = instr_valid_q; // Maybe, if we are here, instr_valid_q = '1'
      end


    endcase // state


    // JUMP, BRANCH, SPECIAL JUMP control
    if(branch_i) begin
      update_state = 1'b1;
      if (branch_is_jump_i && !id_valid_i) begin
        /*
          When ID stalls and there is a JUMP in ID, save it, and wait for a ID valid!
          Otherwise, it can be overwritten by the state update of the aligner.
          When the stall is resolved, the saved JUMP will percolate through the pipe and update the RF.
          We save only JUMPS, because we don't want to save useless instructions in ID when branching from EX
        */
        pc_n         = pc_q;
        next_state   = WAIT_VALID_BRANCH;
      end else begin
        /*
          If there is a JUMP with no stalls, the updating of the state cannot delete the JUMP because it can go in EX
          If ID stalls and we are BRANCHNG from EX, the instruction in ID can be trashed
          If ID stalls and we are jumping for a special instruction in ID (ecall, ...), the instruction was already executed
        */
        pc_n          = branch_addr_i;
        next_state    = branch_addr_i[1] ? BRANCH_MISALIGNED : ALIGNED32;
      end
    end

  end

endmodule

/*
  When a branch is taken in EX, id_valid_i is asserted because the BRANCH is resolved also in
  case of stalls. This is because the branch information is stored in the IF stage (in the prefetcher)
  when branch_i is asserted. We introduced here an apparently unuseful  special case for
  the JUMPS for a cleaner and more robust HW: theoretically, we don't need to save the instruction
  after a taken branch in EX, thus we will not do it.
*/

/*
*** hold_state_i : when an ecall is decoded, the processor needs to save the related PC in MEPC.
                   This operation is performed in the cycle after the ecall is detected.
                   Therefore, we need not to update the PC between those two cycles.
*/
