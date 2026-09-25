// ============================================================================
// nbody_accelerator_fp32.sv  —  IEEE-754 float32 Pairwise Gravity Accelerator
//
// Numeric format: IEEE-754 float32 (1 sign + 8 exponent, bias 127 + 23
// mantissa bits, 24-bit significand with implicit leading 1). Chosen over a
// fixed-point (Q16.16) design because Q16.16 cannot represent this workload:
// its ~1.5e-5 resolution underflows 8 of the 10 pairwise force terms to
// exactly zero. Float32's ~7 decimal digits of precision keeps the
// benchmark's energy nearly conserved (see NBODY_FP32_ACCELERATOR.md).
//
// Numeric simplification: fp_sqrt/fp_div assume non-negative, positive-only,
// normal finite operands (always true for d^2 and d^2*sqrt(d^2) in this
// workload). No NaN/Inf/denormal handling.
//
// Register map (4-byte aligned, 32-bit bus):
//   0x00  CONTROL   bit0=START
//   0x04  STATUS    bit0=BUSY, bit1=DONE (sticky, clear-on-read)
//   0x08  DT        float32 timestep (default 0.01 = 0x3C23D70A)
//   0x0C  N_ITER    iteration count
//   0x40-0xC8  BODY_STATE[0..34]  35 x float32 words (140 bytes)
//   BUG FIX: end address was originally written as 0x8C (that's the SIZE of
//   the region, 35*4=140=0x8C, not its last address). Starting at 0x40, the
//   last word (index 34) is actually at 0x40+34*4=0xC8. The old 0x8C bound
//   silently dropped every MMIO write/read at index >= 20 (bodies 3 and 4,
//   i.e. uranus and neptune, never loaded or read back correctly). Found and
//   fixed via tb_nbody_full_fp32.sv (see NBODY_FP32_ACCELERATOR.md).
// ============================================================================


// ----------------------------------------------------------------------------
// fp_mul: combinational IEEE-754 float32 multiply. Latency: 0 cycles.
// ----------------------------------------------------------------------------
module fp_mul (
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] p
);
    logic        sa, sb, sp;
    logic [7:0]  ea, eb;
    logic [23:0] ma, mb;
    logic [47:0] mp;
    logic [8:0]  ep_wide;
    logic [7:0]  ep;
    logic [22:0] mr;

    assign sa = a[31];
    assign sb = b[31];
    assign ea = a[30:23];
    assign eb = b[30:23];
    assign ma = {1'b1, a[22:0]};   // restore implicit leading 1
    assign mb = {1'b1, b[22:0]};

    assign mp = ma * mb;            // 24x24 -> 48-bit product (Q1.23 x Q1.23 = Q2.46)
    assign sp = sa ^ sb;

    // mp[47]=1 means mantissa product >= 2.0 -> right-shift, add 1 to exponent
    assign ep_wide = mp[47] ? ({1'b0, ea} + {1'b0, eb} - 9'd126)
                             : ({1'b0, ea} + {1'b0, eb} - 9'd127);
    assign ep = ep_wide[7:0];
    assign mr = mp[47] ? mp[46:24] : mp[45:23];

    assign p = {sp, ep, mr};
endmodule


// ----------------------------------------------------------------------------
// fp_sqrt: iterative IEEE-754 float32 square root.
// Non-restoring digit-recurrence sqrt on a 48-bit radicand, producing a
// 24-bit integer result (bit 23 = implicit leading 1).
//
// Radicand construction (M = {1'b1, x[22:0]}, the 24-bit significand):
//   e odd  (e_unbiased even): radicand = {1'b0, M, 23'b0}  -> M x 2^23
//                              res_exp = (e + 127) / 2
//   e even (e_unbiased odd):  radicand = {M, 24'b0}         -> M x 2^24
//                              res_exp = (e + 126) / 2
// Parity of the BIASED exponent is checked via its LSB, x[23] (the least
// significant bit of the 8-bit exponent field x[30:23]).
//
// Latency: 25 cycles (1 setup + 24 bit-pair iterations).
// ----------------------------------------------------------------------------
module fp_sqrt (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic [31:0] x,         // IEEE-754 float32, non-negative
    output logic [31:0] result,    // IEEE-754 float32
    output logic        done
);
    logic [7:0]  res_exp;
    logic [47:0] radicand;
    logic [47:0] rem, root;
    logic [4:0]  i;                // counts 23 down to 0 (24 iterations)

    typedef enum logic [1:0] {IDLE, RUN, DONE_S} state_t;
    state_t state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            done  <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        // BUG FIX (found via tb_fp32_units.sv): x[30:23]+127 can
                        // reach 256 (e.g. exp=129 -> 4.0), which overflows an
                        // 8-bit sum before the >>1. Widen to 9 bits first.
                        if (x[23]) begin  // biased exponent LSB set -> exponent is odd
                            radicand <= {1'b0, 1'b1, x[22:0], 23'b0};   // M x 2^23
                            res_exp  <= ({1'b0, x[30:23]} + 9'd127) >> 1;
                        end else begin    // exponent is even
                            radicand <= {1'b1, x[22:0], 24'b0};          // M x 2^24
                            res_exp  <= ({1'b0, x[30:23]} + 9'd126) >> 1;
                        end
                        rem   <= 48'b0;
                        root  <= 48'b0;
                        i     <= 5'd23;
                        state <= RUN;
                    end
                end

                RUN: begin
                    if ({rem[45:0], radicand[2*i +: 2]} >= {root[45:0], 2'b01}) begin
                        rem  <= {rem[45:0], radicand[2*i +: 2]} - {root[45:0], 2'b01};
                        root <= {root[46:0], 1'b1};
                    end else begin
                        rem  <= {rem[45:0], radicand[2*i +: 2]};
                        root <= {root[46:0], 1'b0};
                    end
                    if (i == 5'd0) state <= DONE_S;
                    else           i <= i - 5'd1;
                end

                DONE_S: begin
                    done  <= 1'b1;
                    state <= IDLE;
                end
            endcase
        end
    end

    // root[23:0] holds the 24-bit isqrt result after 24 iterations.
    // root[23] is the implicit leading 1; root[22:0] are the 23 mantissa bits.
    assign result = {1'b0, res_exp, root[22:0]};

endmodule


// ----------------------------------------------------------------------------
// fp_div: iterative IEEE-754 float32 divide (a / b).
// Restoring long division on a 25-bit mantissa quotient.
//
// Mantissa setup:
//   dividend = Ma x 2^24  (48-bit: {Ma, 24'b0}, Ma = {1'b1, a[22:0]})
//   divisor  = Mb          (24-bit, zero-extended for comparison)
//   25 iterations -> 25-bit quotient Q
//
// Normalization:
//   Q[24]=1 (Ma >= Mb): result_exp = ea - eb + 127, mantissa = Q[23:1]
//   Q[24]=0 (Ma < Mb):  result_exp = ea - eb + 126, mantissa = Q[22:0]
//
// Latency: 49 cycles (1 setup + 48 iterations - the dividend register is
// 48 bits wide (Ma<<24), and every one of those bits must be shifted
// through for a correct result; see bug-fix note above u_div's state
// declarations for how this was found and confirmed).
// ----------------------------------------------------------------------------
module fp_div (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic [31:0] a,         // numerator, IEEE-754 float32
    input  logic [31:0] b,         // denominator, IEEE-754 float32
    output logic [31:0] result,    // IEEE-754 float32
    output logic        done
);
    logic       sr;
    logic [7:0] ea, eb;
    logic [23:0] Ma, Mb;

    logic [47:0] dividend;
    logic [48:0] remainder;
    // BUG FIX (found via tb_fp32_units.sv + hand-verified in Python): this
    // is bit-serial restoring division that shifts ONE new dividend bit
    // into the remainder per cycle. Since `dividend` is 48 bits wide (Ma
    // shifted left by 24 to get fractional precision), it takes 48
    // iterations to actually shift every one of those bits through - not
    // 25. Running only 25 iterations left the quotient's high-order bits
    // catastrophically wrong (e.g. 6.0/2.0 computed as ~1.0000004 instead
    // of 3.0). quotient is widened to 48 bits to match; only its low 25
    // bits end up meaningful (quotient[24] still correctly distinguishes
    // Ma>=Mb from Ma<Mb, unchanged from before - only the iteration count
    // and register widths needed to change).
    logic [47:0] quotient;
    logic [5:0]  i;          // counts 47 down to 0 (48 iterations)

    logic [7:0] exp_base;

    wire [48:0] partial_rem = {remainder[47:0], dividend[47]};
    wire [48:0] div_cmp     = {25'b0, Mb};

    typedef enum logic [1:0] {IDLE, RUN, DONE_D} state_t;
    state_t state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            done  <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        sr        <= a[31] ^ b[31];
                        ea        <= a[30:23];
                        eb        <= b[30:23];
                        Ma        <= {1'b1, a[22:0]};
                        Mb        <= {1'b1, b[22:0]};
                        dividend  <= {{1'b1, a[22:0]}, 24'b0};   // Ma x 2^24
                        exp_base  <= a[30:23] - b[30:23] + 8'd127;
                        remainder <= 49'b0;
                        quotient  <= 48'b0;
                        i         <= 6'd47;
                        state     <= RUN;
                    end
                end

                RUN: begin
                    dividend <= {dividend[46:0], 1'b0};
                    if (partial_rem >= div_cmp) begin
                        remainder <= partial_rem - div_cmp;
                        quotient  <= {quotient[46:0], 1'b1};
                    end else begin
                        remainder <= partial_rem;
                        quotient  <= {quotient[46:0], 1'b0};
                    end
                    if (i == 6'd0) state <= DONE_D;
                    else           i <= i - 6'd1;
                end

                DONE_D: begin
                    done  <= 1'b1;
                    state <= IDLE;
                end
            endcase
        end
    end

    wire [7:0]  res_exp  = quotient[24] ? exp_base       : exp_base - 8'd1;
    wire [22:0] res_mant = quotient[24] ? quotient[23:1] : quotient[22:0];
    assign result = {sr, res_exp, res_mant};

endmodule


// ----------------------------------------------------------------------------
// fp_add: combinational IEEE-754 float32 add/subtract. Latency: 0 cycles.
// ----------------------------------------------------------------------------
module fp_add (
    input  logic [31:0] a, b,
    output logic [31:0] s
);
    wire        sa = a[31], sb = b[31];
    wire [7:0]  ea = a[30:23], eb = b[30:23];
    wire [23:0] Ma = {1'b1, a[22:0]}, Mb = {1'b1, b[22:0]};

    wire mag_swap  = (eb > ea) || ((eb == ea) && (Mb > Ma));
    wire [7:0]  e_big = mag_swap ? eb : ea;
    wire [7:0]  e_sml = mag_swap ? ea : eb;
    wire [23:0] M_big = mag_swap ? Mb : Ma;
    wire [23:0] M_sml = mag_swap ? Ma : Mb;
    wire        s_big = mag_swap ? sb : sa;
    wire        s_sml = mag_swap ? sa : sb;

    wire [7:0]  shamt  = e_big - e_sml;
    wire [24:0] A_ext  = {1'b0, M_big};
    wire [24:0] B_ext  = (shamt >= 8'd25) ? 25'b0 : ({1'b0, M_sml} >> shamt);

    wire do_add = (s_big == s_sml);
    wire [25:0] raw = do_add ? ({1'b0, A_ext} + {1'b0, B_ext})
                              : ({1'b0, A_ext} - {1'b0, B_ext});

    logic [4:0]  lz;
    logic        lz_found;
    logic [23:0] normed;
    logic [22:0] res_mant;
    logic [7:0]  res_exp;

    always_comb begin
        // BUG FIX (found via tb_fp32_units.sv): the loop must stop at the
        // FIRST (highest) set bit when scanning top-down. Without break, it
        // kept overwriting lz on every set bit, ending up with the position
        // of the LOWEST set bit instead of the count of leading zeros -
        // wrong whenever raw has more than one high-order 1 bit, which is
        // the common case for addition (e.g. 3.0+4.0 -> raw=0xE00000,
        // correct lz=0, buggy version computed lz=2).
        lz = 5'd23;
        lz_found = 1'b0;
        for (int k = 23; k >= 0; k--) begin
            if (raw[k] && !lz_found) begin
                lz = 5'(23 - k);
                lz_found = 1'b1;
            end
        end

        normed   = raw[23:0] << lz;
        res_mant = 23'b0;
        res_exp  = 8'b0;

        if (raw[24:0] == 25'b0) begin
            res_exp  = 8'b0;
            res_mant = 23'b0;
        end else if (raw[24]) begin
            res_exp  = e_big + 8'd1;
            res_mant = raw[23:1];
        end else begin
            res_exp  = (e_big >= {3'b0, lz}) ? (e_big - {3'b0, lz}) : 8'b0;
            res_mant = normed[22:0];
        end
    end

    assign s = {s_big, res_exp, res_mant};
endmodule


// ----------------------------------------------------------------------------
// body_regfile: 35 x 32-bit words (140 bytes on-chip). Layout unchanged:
// index = body*7 + field, fields 0-2=pos, 3-5=vel, 6=mass.
// ----------------------------------------------------------------------------
module body_regfile (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        host_we,
    input  logic [5:0]  host_addr,
    input  logic [31:0] host_wdata,
    output logic [31:0] host_rdata,
    input  logic        core_we,
    input  logic [5:0]  core_addr,
    input  logic [31:0] core_wdata,
    output logic [31:0] core_rdata
);
    logic [31:0] mem [0:34];

    always_ff @(posedge clk) begin
        if      (host_we) mem[host_addr] <= host_wdata;
        else if (core_we) mem[core_addr] <= core_wdata;
    end

    assign host_rdata = mem[host_addr];
    assign core_rdata = mem[core_addr];
endmodule


// ----------------------------------------------------------------------------
// pair_rom: unchanged — 10 fixed body-pair indices, purely combinational.
// ----------------------------------------------------------------------------
module pair_rom (
    input  logic [3:0] addr,
    output logic [2:0] body_i,
    output logic [2:0] body_j
);
    always_comb begin
        case (addr)
            4'd0: begin body_i = 0; body_j = 1; end // sun-jupiter
            4'd1: begin body_i = 0; body_j = 2; end // sun-saturn
            4'd2: begin body_i = 0; body_j = 3; end // sun-uranus
            4'd3: begin body_i = 0; body_j = 4; end // sun-neptune
            4'd4: begin body_i = 1; body_j = 2; end // jupiter-saturn
            4'd5: begin body_i = 1; body_j = 3; end // jupiter-uranus
            4'd6: begin body_i = 1; body_j = 4; end // jupiter-neptune
            4'd7: begin body_i = 2; body_j = 3; end // saturn-uranus
            4'd8: begin body_i = 2; body_j = 4; end // saturn-neptune
            4'd9: begin body_i = 3; body_j = 4; end // uranus-neptune
            default: begin body_i = 0; body_j = 0; end
        endcase
    end
endmodule


// ----------------------------------------------------------------------------
// nbody_core: FSM and datapath — IEEE-754 float32. 21-state control FSM;
// every scratch register and math-unit port is [31:0].
// ----------------------------------------------------------------------------
module nbody_core (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic [31:0] dt,
    input  logic [31:0] n_iterations,
    output logic        busy,
    output logic        done,
    output logic        rf_we,
    output logic [5:0]  rf_addr,
    output logic [31:0] rf_wdata,
    input  logic [31:0] rf_rdata
);
    typedef enum logic [4:0] {
        S_IDLE,
        S_LOAD_I, S_LOAD_J,
        S_SUB,
        S_SQ_X, S_SQ_Y, S_SQ_Z,
        S_SUM_1, S_SUM_2,
        S_SQRT_LAUNCH, S_SQRT_WAIT,
        S_DENOM, S_DENOM_WAIT,
        S_DIV_LAUNCH, S_DIV_WAIT,
        S_MASSMUL_I, S_MASSMUL_J, S_MASSMUL_WAIT,
        S_VELUPD,
        S_WB_I, S_WB_J,
        S_NEXTPAIR,
        S_POSUPD
    } state_t;
    state_t state;

    logic [3:0]  pair_idx;
    logic [31:0] iter_cnt;
    logic [2:0]  bi, bj, body_idx;
    logic [2:0]  sub;
    logic [3:0]  pos_step;

    logic [2:0] pr_i, pr_j;
    pair_rom u_pair_rom (.addr(pair_idx), .body_i(pr_i), .body_j(pr_j));

    logic [31:0] xi, yi, zi, xj, yj, zj;
    logic [31:0] vxi, vyi, vzi, vxj, vyj, vzj;
    logic [31:0] mi, mj;
    logic [31:0] dx, dy, dz;
    logic [31:0] dxsq, dysq, dzsq, sum1, d2;
    logic [31:0] sqrt_d2, denom, mag, b_im, b_jm;
    logic [31:0] dtVx, dtVy, dtVz;
    logic [31:0] px, py, pz;
    logic [31:0] x_new, y_new, z_new;

    logic [31:0] fadd_a, fadd_b, fadd_s, fadd_s_reg;
    fp_add u_add (.a(fadd_a), .b(fadd_b), .s(fadd_s));
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) fadd_s_reg <= '0;
        else        fadd_s_reg <= fadd_s;

    logic [31:0] mul_a, mul_b, mul_p;
    fp_mul u_mul (.a(mul_a), .b(mul_b), .p(mul_p));

    logic        sqrt_start, sqrt_done;
    logic [31:0] sqrt_result;
    fp_sqrt u_sqrt (.clk(clk), .rst_n(rst_n), .start(sqrt_start),
                    .x(d2), .result(sqrt_result), .done(sqrt_done));

    logic        div_start, div_done;
    logic [31:0] div_result;
    fp_div u_div (.clk(clk), .rst_n(rst_n), .start(div_start),
                  .a(dt), .b(denom), .result(div_result), .done(div_done));

    // BUG FIX: rf_we used to be driven from the sequential (always_ff) block
    // as `rf_we <= 1'b1` inside each write-intending state, while rf_addr/
    // rf_wdata are combinational (always_comb, valid the SAME cycle as the
    // state/sub they belong to). Since a registered rf_we only takes effect
    // one cycle AFTER the case branch that set it, it landed one cycle late
    // relative to rf_addr/rf_wdata - which by then had already advanced to
    // the NEXT sub-step. Symptom: found via tb_nbody_full_fp32.sv - every
    // "i"-body's vx write in S_WB_I (sub=0) was silently dropped (rf_we was
    // still 0, carried over from S_VELUPD, when addr/data were already
    // valid for sub=0), and S_POSUPD's last primed rf_we (from pos_step=9)
    // leaked into the FIRST cycle of the NEXT body's pos_step=0 (a READ
    // step), spuriously writing 0 to that body's vx register. Net effect:
    // every non-sun body's vx ended up hard-zeroed after position update.
    // Fix: drive rf_we combinationally, in the same always_comb block and
    // on the same cycle as rf_addr/rf_wdata, so write-enable and the
    // address/data it applies to are never one cycle apart.
    always_comb begin
        rf_addr  = 6'b0;
        rf_wdata = 32'b0;
        rf_we    = 1'b0;
        fadd_a   = 32'b0;
        fadd_b   = 32'b0;

        case (state)
            S_LOAD_I: rf_addr = 6'(pr_i) * 6'd7 + {3'b0, sub};
            S_LOAD_J: rf_addr = 6'(pr_j) * 6'd7 + {3'b0, sub};

            S_SUB: case (sub)
                3'd0: begin fadd_a=xi; fadd_b={~xj[31],xj[30:0]}; end
                3'd1: begin fadd_a=yi; fadd_b={~yj[31],yj[30:0]}; end
                3'd2: begin fadd_a=zi; fadd_b={~zj[31],zj[30:0]}; end
                default: ;
            endcase

            S_SUM_1: begin fadd_a=dxsq; fadd_b=dysq; end
            S_SUM_2: begin fadd_a=sum1; fadd_b=dzsq; end

            S_VELUPD: case (sub)
                3'd0: begin fadd_a=vxi; fadd_b={~mul_p[31],mul_p[30:0]}; end
                3'd1: begin fadd_a=vyi; fadd_b={~mul_p[31],mul_p[30:0]}; end
                3'd2: begin fadd_a=vzi; fadd_b={~mul_p[31],mul_p[30:0]}; end
                3'd3: begin fadd_a=vxj; fadd_b=mul_p; end
                3'd4: begin fadd_a=vyj; fadd_b=mul_p; end
                3'd5: begin fadd_a=vzj; fadd_b=mul_p; end
                default: ;
            endcase

            S_WB_I: begin
                rf_addr  = 6'(bi) * 6'd7 + 6'd3 + {3'b0, sub};
                rf_wdata = (sub==3'd0) ? vxi : (sub==3'd1) ? vyi : vzi;
                rf_we    = 1'b1;
            end
            S_WB_J: begin
                rf_addr  = 6'(bj) * 6'd7 + 6'd3 + {3'b0, sub};
                rf_wdata = (sub==3'd0) ? vxj : (sub==3'd1) ? vyj : vzj;
                rf_we    = 1'b1;
            end

            S_POSUPD: case (pos_step)
                4'd0: rf_addr = 6'(body_idx)*6'd7 + 6'd3;
                4'd1: rf_addr = 6'(body_idx)*6'd7 + 6'd4;
                4'd2: rf_addr = 6'(body_idx)*6'd7 + 6'd5;
                4'd3: rf_addr = 6'(body_idx)*6'd7 + 6'd0;
                4'd4: begin rf_addr=6'(body_idx)*6'd7+6'd1; fadd_a=px;  fadd_b=dtVx; end
                4'd5: begin rf_addr=6'(body_idx)*6'd7+6'd2; fadd_a=py;  fadd_b=dtVy; end
                4'd6: begin                                  fadd_a=pz;  fadd_b=dtVz; end
                4'd7: begin rf_addr=6'(body_idx)*6'd7+6'd0; rf_wdata=x_new; rf_we=1'b1; end
                4'd8: begin rf_addr=6'(body_idx)*6'd7+6'd1; rf_wdata=y_new; rf_we=1'b1; end
                4'd9: begin rf_addr=6'(body_idx)*6'd7+6'd2; rf_wdata=z_new; rf_we=1'b1; end
                default: ;
            endcase

            default: ;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE; busy <= '0; done <= '0;
            pair_idx   <= '0; iter_cnt <= '0;
            body_idx   <= '0; bi <= '0; bj <= '0;
            sub        <= '0; pos_step <= '0;
            sqrt_start <= '0; div_start <= '0;
        end else begin
            done <= '0; sqrt_start <= '0; div_start <= '0;

            case (state)
                S_IDLE: begin
                    busy <= '0;
                    if (start) begin
                        busy <= 1'b1; iter_cnt <= n_iterations;
                        pair_idx <= '0; sub <= '0; state <= S_LOAD_I;
                    end
                end

                S_LOAD_I: begin
                    if (sub == 3'd0) begin bi <= pr_i; bj <= pr_j; end
                    case (sub)
                        3'd0: xi  <= rf_rdata;
                        3'd1: yi  <= rf_rdata;
                        3'd2: zi  <= rf_rdata;
                        3'd3: vxi <= rf_rdata;
                        3'd4: vyi <= rf_rdata;
                        3'd5: vzi <= rf_rdata;
                        3'd6: begin mi <= rf_rdata; sub <= '0; state <= S_LOAD_J; end
                    endcase
                    if (sub != 3'd6) sub <= sub + 3'd1;
                end

                S_LOAD_J: begin
                    case (sub)
                        3'd0: xj  <= rf_rdata;
                        3'd1: yj  <= rf_rdata;
                        3'd2: zj  <= rf_rdata;
                        3'd3: vxj <= rf_rdata;
                        3'd4: vyj <= rf_rdata;
                        3'd5: vzj <= rf_rdata;
                        3'd6: begin mj <= rf_rdata; sub <= '0; state <= S_SUB; end
                    endcase
                    if (sub != 3'd6) sub <= sub + 3'd1;
                end

                S_SUB: begin
                    case (sub)
                        3'd0: begin dx <= fadd_s; sub <= 3'd1; end
                        3'd1: begin dy <= fadd_s; sub <= 3'd2; end
                        3'd2: begin dz <= fadd_s; sub <= '0; state <= S_SQ_X; end
                    endcase
                end

                S_SQ_X: begin mul_a<=dx;   mul_b<=dx;  state<=S_SQ_Y; end
                S_SQ_Y: begin dxsq<=mul_p; mul_a<=dy;  mul_b<=dy; state<=S_SQ_Z; end
                S_SQ_Z: begin dysq<=mul_p; mul_a<=dz;  mul_b<=dz; state<=S_SUM_1; end

                S_SUM_1: begin dzsq<=mul_p; sum1<=fadd_s; state<=S_SUM_2; end
                S_SUM_2: begin d2<=fadd_s; state<=S_SQRT_LAUNCH; end
                S_SQRT_LAUNCH: begin sqrt_start<=1'b1; state<=S_SQRT_WAIT; end
                S_SQRT_WAIT:   if (sqrt_done) begin sqrt_d2<=sqrt_result; state<=S_DENOM; end

                S_DENOM:      begin mul_a<=d2;   mul_b<=sqrt_d2; state<=S_DENOM_WAIT; end
                S_DENOM_WAIT: begin denom<=mul_p; state<=S_DIV_LAUNCH; end
                S_DIV_LAUNCH: begin div_start<=1'b1; state<=S_DIV_WAIT; end
                S_DIV_WAIT:   if (div_done) begin mag<=div_result; state<=S_MASSMUL_I; end

                S_MASSMUL_I: begin mul_a<=mj; mul_b<=mag; state<=S_MASSMUL_J; end
                S_MASSMUL_J: begin b_im<=mul_p; mul_a<=mi; mul_b<=mag; state<=S_MASSMUL_WAIT; end
                S_MASSMUL_WAIT: begin
                    b_jm  <= mul_p;
                    mul_a <= dx; mul_b <= b_im;
                    sub   <= '0; state <= S_VELUPD;
                end

                S_VELUPD: begin
                    case (sub)
                        3'd0: begin vxi<=fadd_s; mul_a<=dy;  mul_b<=b_im; sub<=3'd1; end
                        3'd1: begin vyi<=fadd_s; mul_a<=dz;  mul_b<=b_im; sub<=3'd2; end
                        3'd2: begin vzi<=fadd_s; mul_a<=dx;  mul_b<=b_jm; sub<=3'd3; end
                        3'd3: begin vxj<=fadd_s; mul_a<=dy;  mul_b<=b_jm; sub<=3'd4; end
                        3'd4: begin vyj<=fadd_s; mul_a<=dz;  mul_b<=b_jm; sub<=3'd5; end
                        3'd5: begin vzj<=fadd_s; sub<='0; state<=S_WB_I; end
                    endcase
                end

                S_WB_I: begin
                    if (sub==3'd2) begin sub<='0; state<=S_WB_J; end
                    else           sub<=sub+3'd1;
                end
                S_WB_J: begin
                    if (sub==3'd2) begin sub<='0; state<=S_NEXTPAIR; end
                    else           sub<=sub+3'd1;
                end

                S_NEXTPAIR: begin
                    if (pair_idx==4'd9) begin
                        pair_idx<='0; body_idx<='0; pos_step<='0; state<=S_POSUPD;
                    end else begin
                        pair_idx<=pair_idx+4'd1; sub<='0; state<=S_LOAD_I;
                    end
                end

                S_POSUPD: begin
                    case (pos_step)
                        4'd0: begin mul_a<=dt; mul_b<=rf_rdata; pos_step<=4'd1; end
                        4'd1: begin dtVx<=mul_p; mul_a<=dt; mul_b<=rf_rdata; pos_step<=4'd2; end
                        4'd2: begin dtVy<=mul_p; mul_a<=dt; mul_b<=rf_rdata; pos_step<=4'd3; end
                        4'd3: begin dtVz<=mul_p; px<=rf_rdata; pos_step<=4'd4; end
                        4'd4: begin py<=rf_rdata; pos_step<=4'd5; end
                        4'd5: begin pz<=rf_rdata; x_new<=fadd_s_reg; pos_step<=4'd6; end
                        4'd6: begin              y_new<=fadd_s_reg; pos_step<=4'd7; end
                        4'd7: begin z_new<=fadd_s_reg; pos_step<=4'd8; end
                        4'd8: begin pos_step<=4'd9; end
                        4'd9: begin
                            pos_step <= '0;
                            if (body_idx==3'd4) begin
                                body_idx <= '0;
                                if (iter_cnt==32'd1) begin
                                    done<=1'b1; busy<=1'b0; state<=S_IDLE;
                                end else begin
                                    iter_cnt<=iter_cnt-32'd1; pair_idx<='0; sub<='0;
                                    state<=S_LOAD_I;
                                end
                            end else body_idx<=body_idx+3'd1;
                        end
                    endcase
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule


// ----------------------------------------------------------------------------
// nbody_accelerator: top-level MMIO wrapper. 32-bit data/addr bus.
// Register map: 0x00=CONTROL, 0x04=STATUS, 0x08=DT, 0x0C=N_ITER,
//               0x40-0xC8=BODY_STATE[0..34] (35 x 4 bytes).
// ----------------------------------------------------------------------------
module nbody_accelerator (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        mmio_we,
    input  logic        mmio_re,
    input  logic [7:0]  mmio_addr,
    input  logic [31:0] mmio_wdata,
    output logic [31:0] mmio_rdata,

    output logic        irq
);
    logic core_start, core_busy, core_done;
    logic [31:0] core_dt;
    logic [31:0] core_n_iter;

    logic        rf_host_we;
    logic [5:0]  rf_host_addr;
    logic [31:0] rf_host_wdata, rf_host_rdata;
    logic        rf_core_we;
    logic [5:0]  rf_core_addr;
    logic [31:0] rf_core_wdata, rf_core_rdata;

    body_regfile u_regfile (
        .clk(clk), .rst_n(rst_n),
        .host_we(rf_host_we), .host_addr(rf_host_addr),
        .host_wdata(rf_host_wdata), .host_rdata(rf_host_rdata),
        .core_we(rf_core_we), .core_addr(rf_core_addr),
        .core_wdata(rf_core_wdata), .core_rdata(rf_core_rdata)
    );

    nbody_core u_core (
        .clk(clk), .rst_n(rst_n),
        .start(core_start), .dt(core_dt), .n_iterations(core_n_iter),
        .busy(core_busy), .done(core_done),
        .rf_we(rf_core_we), .rf_addr(rf_core_addr),
        .rf_wdata(rf_core_wdata), .rf_rdata(rf_core_rdata)
    );

    logic sticky_done;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            core_start    <= 1'b0;
            core_dt       <= 32'h3C23D70A; // 0.01 in IEEE-754 float32
            core_n_iter   <= 32'd20000;
            sticky_done   <= 1'b0;
            rf_host_we    <= 1'b0;
            rf_host_wdata <= 32'b0;
            irq           <= 1'b0;
        end else begin
            core_start <= 1'b0;
            rf_host_we <= 1'b0;
            irq        <= 1'b0;

            if (core_done) begin
                sticky_done <= 1'b1;
                irq         <= 1'b1;
            end

            if (mmio_we) begin
                case (mmio_addr)
                    8'h00: if (mmio_wdata[0]) core_start <= 1'b1;
                    8'h08: core_dt     <= mmio_wdata;
                    8'h0C: core_n_iter <= mmio_wdata;
                    default: begin
                        if (mmio_addr >= 8'h40 && mmio_addr <= 8'hC8) begin
                            rf_host_we    <= 1'b1;
                            rf_host_wdata <= mmio_wdata;
                        end
                    end
                endcase
            end

            if (mmio_re && mmio_addr == 8'h04)
                sticky_done <= 1'b0;
        end
    end

    always_comb begin
        rf_host_addr = (mmio_addr >= 8'h40) ? (mmio_addr - 8'h40) >> 2 : 6'b0;
        mmio_rdata   = 32'b0;
        if (mmio_addr == 8'h04)
            mmio_rdata = {30'b0, sticky_done, core_busy};
        else if (mmio_addr >= 8'h40 && mmio_addr <= 8'hC8)
            mmio_rdata = rf_host_rdata;
    end

endmodule
