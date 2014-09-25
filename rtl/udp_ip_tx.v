/*

Copyright (c) 2014 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`timescale 1ns / 1ps

/*
 * UDP ethernet frame transmitter (UDP frame in, IP frame out)
 */
module udp_ip_tx
(
    input  wire        clk,
    input  wire        rst,

    /*
     * UDP frame input
     */
    input  wire        input_udp_hdr_valid,
    output wire        input_udp_hdr_ready,
    input  wire [47:0] input_eth_dest_mac,
    input  wire [47:0] input_eth_src_mac,
    input  wire [15:0] input_eth_type,
    input  wire [3:0]  input_ip_version,
    input  wire [3:0]  input_ip_ihl,
    input  wire [5:0]  input_ip_dscp,
    input  wire [1:0]  input_ip_ecn,
    input  wire [15:0] input_ip_identification,
    input  wire [2:0]  input_ip_flags,
    input  wire [12:0] input_ip_fragment_offset,
    input  wire [7:0]  input_ip_ttl,
    input  wire [7:0]  input_ip_protocol,
    input  wire [15:0] input_ip_header_checksum,
    input  wire [31:0] input_ip_source_ip,
    input  wire [31:0] input_ip_dest_ip,
    input  wire [15:0] input_udp_source_port,
    input  wire [15:0] input_udp_dest_port,
    input  wire [15:0] input_udp_length,
    input  wire [15:0] input_udp_checksum,
    input  wire [7:0]  input_udp_payload_tdata,
    input  wire        input_udp_payload_tvalid,
    output wire        input_udp_payload_tready,
    input  wire        input_udp_payload_tlast,
    input  wire        input_udp_payload_tuser,

    /*
     * IP frame output
     */
    output wire        output_ip_hdr_valid,
    input  wire        output_ip_hdr_ready,
    output wire [47:0] output_eth_dest_mac,
    output wire [47:0] output_eth_src_mac,
    output wire [15:0] output_eth_type,
    output wire [3:0]  output_ip_version,
    output wire [3:0]  output_ip_ihl,
    output wire [5:0]  output_ip_dscp,
    output wire [1:0]  output_ip_ecn,
    output wire [15:0] output_ip_length,
    output wire [15:0] output_ip_identification,
    output wire [2:0]  output_ip_flags,
    output wire [12:0] output_ip_fragment_offset,
    output wire [7:0]  output_ip_ttl,
    output wire [7:0]  output_ip_protocol,
    output wire [15:0] output_ip_header_checksum,
    output wire [31:0] output_ip_source_ip,
    output wire [31:0] output_ip_dest_ip,
    output wire [7:0]  output_ip_payload_tdata,
    output wire        output_ip_payload_tvalid,
    input  wire        output_ip_payload_tready,
    output wire        output_ip_payload_tlast,
    output wire        output_ip_payload_tuser,

    /*
     * Status signals
     */
    output wire        busy,
    output wire        error_payload_early_termination
);

/*

UDP Frame

 Field                       Length
 Destination MAC address     6 octets
 Source MAC address          6 octets
 Ethertype (0x0800)          2 octets
 Version (4)                 4 bits
 IHL (5-15)                  4 bits
 DSCP (0)                    6 bits
 ECN (0)                     2 bits
 length                      2 octets
 identification (0?)         2 octets
 flags (010)                 3 bits
 fragment offset (0)         13 bits
 time to live (64?)          1 octet
 protocol                    1 octet
 header checksum             2 octets
 source IP                   4 octets
 destination IP              4 octets
 options                     (IHL-5)*4 octets

 source port                 2 octets
 desination port             2 octets
 length                      2 octets
 checksum                    2 octets

 payload                     length octets

This module receives an IP frame with decoded fields and decodes
the AXI packet format.  If the Ethertype does not match, the packet is
discarded.

*/

localparam [2:0]
    STATE_IDLE = 3'd0,
    STATE_WRITE_HEADER = 3'd1,
    STATE_WRITE_PAYLOAD_IDLE = 3'd2,
    STATE_WRITE_PAYLOAD_TRANSFER = 3'd3,
    STATE_WRITE_PAYLOAD_TRANSFER_WAIT = 3'd4,
    STATE_WRITE_PAYLOAD_TRANSFER_LAST = 3'd5,
    STATE_WRITE_PAYLOAD_TRANSFER_WAIT_LAST = 3'd6,
    STATE_WAIT_LAST = 3'd7;

reg [2:0] state_reg = STATE_IDLE, state_next;

// datapath control signals
reg store_udp_hdr;

reg [7:0] write_hdr_data;
reg write_hdr_out;

reg transfer_in_out;
reg transfer_in_temp;
reg transfer_temp_out;

reg assert_tlast;
reg assert_tuser;

reg [15:0] frame_ptr_reg = 0, frame_ptr_next;

reg [15:0] hdr_sum_reg = 0, hdr_sum_next;

reg [15:0] udp_source_port_reg = 0;
reg [15:0] udp_dest_port_reg = 0;
reg [15:0] udp_length_reg = 0;
reg [15:0] udp_checksum_reg = 0;

reg input_udp_hdr_ready_reg = 0;
reg input_udp_payload_tready_reg = 0;

reg output_ip_hdr_valid_reg = 0, output_ip_hdr_valid_next;
reg [47:0] output_eth_dest_mac_reg = 0;
reg [47:0] output_eth_src_mac_reg = 0;
reg [15:0] output_eth_type_reg = 0;
reg [3:0] output_ip_version_reg = 0;
reg [3:0] output_ip_ihl_reg = 0;
reg [5:0] output_ip_dscp_reg = 0;
reg [1:0] output_ip_ecn_reg = 0;
reg [15:0] output_ip_length_reg = 0;
reg [15:0] output_ip_identification_reg = 0;
reg [2:0] output_ip_flags_reg = 0;
reg [12:0] output_ip_fragment_offset_reg = 0;
reg [7:0] output_ip_ttl_reg = 0;
reg [7:0] output_ip_protocol_reg = 0;
reg [15:0] output_ip_header_checksum_reg = 0;
reg [31:0] output_ip_source_ip_reg = 0;
reg [31:0] output_ip_dest_ip_reg = 0;
reg [7:0] output_ip_payload_tdata_reg = 0;
reg output_ip_payload_tvalid_reg = 0;
reg output_ip_payload_tlast_reg = 0;
reg output_ip_payload_tuser_reg = 0;

reg busy_reg = 0;
reg error_payload_early_termination_reg = 0, error_payload_early_termination_next;

reg [7:0] temp_ip_payload_tdata_reg = 0;
reg temp_ip_payload_tlast_reg = 0;
reg temp_ip_payload_tuser_reg = 0;

assign input_udp_hdr_ready = input_udp_hdr_ready_reg;
assign input_udp_payload_tready = input_udp_payload_tready_reg;

assign output_ip_hdr_valid = output_ip_hdr_valid_reg;
assign output_eth_dest_mac = output_eth_dest_mac_reg;
assign output_eth_src_mac = output_eth_src_mac_reg;
assign output_eth_type = output_eth_type_reg;
assign output_ip_version = output_ip_version_reg;
assign output_ip_ihl = output_ip_ihl_reg;
assign output_ip_dscp = output_ip_dscp_reg;
assign output_ip_ecn = output_ip_ecn_reg;
assign output_ip_length = output_ip_length_reg;
assign output_ip_identification = output_ip_identification_reg;
assign output_ip_flags = output_ip_flags_reg;
assign output_ip_fragment_offset = output_ip_fragment_offset_reg;
assign output_ip_ttl = output_ip_ttl_reg;
assign output_ip_protocol = output_ip_protocol_reg;
assign output_ip_header_checksum = output_ip_header_checksum_reg;
assign output_ip_source_ip = output_ip_source_ip_reg;
assign output_ip_dest_ip = output_ip_dest_ip_reg;
assign output_ip_payload_tdata = output_ip_payload_tdata_reg;
assign output_ip_payload_tvalid = output_ip_payload_tvalid_reg;
assign output_ip_payload_tlast = output_ip_payload_tlast_reg;
assign output_ip_payload_tuser = output_ip_payload_tuser_reg;

assign busy = busy_reg;
assign error_payload_early_termination = error_payload_early_termination_reg;

always @* begin
    state_next = 2'bz;

    store_udp_hdr = 0;

    write_hdr_data = 0;
    write_hdr_out = 0;

    transfer_in_out = 0;
    transfer_in_temp = 0;
    transfer_temp_out = 0;

    assert_tlast = 0;
    assert_tuser = 0;

    frame_ptr_next = frame_ptr_reg;

    hdr_sum_next = hdr_sum_reg;

    output_ip_hdr_valid_next = output_ip_hdr_valid_reg & ~output_ip_hdr_ready;

    error_payload_early_termination_next = 0;

    case (state_reg)
        STATE_IDLE: begin
            // idle state - wait for data
            frame_ptr_next = 0;

            if (input_udp_hdr_valid & input_udp_hdr_ready) begin
                store_udp_hdr = 1;
                write_hdr_out = 1;
                write_hdr_data = input_udp_source_port[15: 8];
                output_ip_hdr_valid_next = 1;
                frame_ptr_next = 1;
                state_next = STATE_WRITE_HEADER;
            end else begin
                state_next = STATE_IDLE;
            end
        end
        STATE_WRITE_HEADER: begin
            // write header state
            if (output_ip_payload_tready) begin
                // word transfer out
                frame_ptr_next = frame_ptr_reg+1;
                state_next = STATE_WRITE_HEADER;
                write_hdr_out = 1;
                case (frame_ptr_reg)
                    8'h01: write_hdr_data = udp_source_port_reg[ 7: 0];
                    8'h02: write_hdr_data = udp_dest_port_reg[15: 8];
                    8'h03: write_hdr_data = udp_dest_port_reg[ 7: 0];
                    8'h04: write_hdr_data = udp_length_reg[15: 8];
                    8'h05: write_hdr_data = udp_length_reg[ 7: 0];
                    8'h06: write_hdr_data = udp_checksum_reg[15: 8];
                    8'h07: begin
                        write_hdr_data = udp_checksum_reg[ 7: 0];
                        state_next = STATE_WRITE_PAYLOAD_TRANSFER;
                    end
                endcase
            end else begin
                state_next = STATE_WRITE_HEADER;
            end
        end
        STATE_WRITE_PAYLOAD_IDLE: begin
            // idle; no data in registers
            if (input_udp_payload_tvalid) begin
                // word transfer in - store it in output register
                transfer_in_out = 1;
                frame_ptr_next = frame_ptr_reg+1;
                if (input_udp_payload_tlast) begin
                    if (frame_ptr_next != udp_length_reg) begin
                        // end of frame, but length does not match
                        assert_tuser = 1;
                        error_payload_early_termination_next = 1;
                    end
                    state_next = STATE_WRITE_PAYLOAD_TRANSFER_LAST;
                end else begin
                    if (frame_ptr_next == udp_length_reg) begin
                        // not end of frame, but we have the entire payload
                        state_next = STATE_WRITE_PAYLOAD_TRANSFER_WAIT_LAST;
                    end else begin
                        state_next = STATE_WRITE_PAYLOAD_TRANSFER;
                    end
                end
            end else begin
                state_next = STATE_WRITE_PAYLOAD_IDLE;
            end
        end
        STATE_WRITE_PAYLOAD_TRANSFER: begin
            // write payload; data in output register
            if (input_udp_payload_tvalid & output_ip_payload_tready) begin
                // word transfer through - update output register
                transfer_in_out = 1;
                frame_ptr_next = frame_ptr_reg+1;
                if (input_udp_payload_tlast) begin
                    if (frame_ptr_next != udp_length_reg) begin
                        // end of frame, but length does not match
                        assert_tuser = 1;
                        error_payload_early_termination_next = 1;
                    end
                    state_next = STATE_WRITE_PAYLOAD_TRANSFER_LAST;
                end else begin
                    if (frame_ptr_next == udp_length_reg) begin
                        // not end of frame, but we have the entire payload
                        state_next = STATE_WRITE_PAYLOAD_TRANSFER_WAIT_LAST;
                    end else begin
                        state_next = STATE_WRITE_PAYLOAD_TRANSFER;
                    end
                end
            end else if (~input_udp_payload_tvalid & output_ip_payload_tready) begin
                // word transfer out - go back to idle
                state_next = STATE_WRITE_PAYLOAD_IDLE;
            end else if (input_udp_payload_tvalid & ~output_ip_payload_tready) begin
                // word transfer in - store in temp
                transfer_in_temp = 1;
                frame_ptr_next = frame_ptr_reg+1;
                state_next = STATE_WRITE_PAYLOAD_TRANSFER_WAIT;
            end else begin
                state_next = STATE_WRITE_PAYLOAD_TRANSFER;
            end
        end
        STATE_WRITE_PAYLOAD_TRANSFER_WAIT: begin
            // write payload; data in both output and temp registers
            if (output_ip_payload_tready) begin
                // transfer out - move temp to output
                transfer_temp_out = 1;
                if (temp_ip_payload_tlast_reg) begin
                    if (frame_ptr_next != udp_length_reg) begin
                        // end of frame, but length does not match
                        assert_tuser = 1;
                        error_payload_early_termination_next = 1;
                    end
                    state_next = STATE_WRITE_PAYLOAD_TRANSFER_LAST;
                end else begin
                    if (frame_ptr_next == udp_length_reg) begin
                        // not end of frame, but we have the entire payload
                        state_next = STATE_WRITE_PAYLOAD_TRANSFER_WAIT_LAST;
                    end else begin
                        state_next = STATE_WRITE_PAYLOAD_TRANSFER;
                    end
                end
            end else begin
                state_next = STATE_WRITE_PAYLOAD_TRANSFER_WAIT;
            end
        end
        STATE_WRITE_PAYLOAD_TRANSFER_LAST: begin
            // write last payload word; data in output register; do not accept new data
            if (output_ip_payload_tready) begin
                // word transfer out - done
                state_next = STATE_IDLE;
            end else begin
                state_next = STATE_WRITE_PAYLOAD_TRANSFER_LAST;
            end
        end
        STATE_WRITE_PAYLOAD_TRANSFER_WAIT_LAST: begin
            // wait for end of frame; data in output register; read and discard
            if (input_udp_payload_tvalid) begin
                if (input_udp_payload_tlast) begin
                    // assert tlast and transfer tuser
                    assert_tlast = 1;
                    assert_tuser = input_udp_payload_tuser;
                    state_next = STATE_WRITE_PAYLOAD_TRANSFER_LAST;
                end else begin
                    state_next = STATE_WRITE_PAYLOAD_TRANSFER_WAIT_LAST;
                end
            end else begin
                state_next = STATE_WRITE_PAYLOAD_TRANSFER_WAIT_LAST;
            end
        end
        STATE_WAIT_LAST: begin
            // wait for end of frame; read and discard
            if (input_udp_payload_tvalid) begin
                if (input_udp_payload_tlast) begin
                    state_next = STATE_IDLE;
                end else begin
                    state_next = STATE_WAIT_LAST;
                end
            end else begin
                state_next = STATE_WAIT_LAST;
            end
        end
    endcase
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state_reg <= STATE_IDLE;
        frame_ptr_reg <= 0;
        hdr_sum_reg <= 0;
        input_udp_hdr_ready_reg <= 0;
        input_udp_payload_tready_reg <= 0;
        udp_source_port_reg <= 0;
        udp_dest_port_reg <= 0;
        udp_length_reg <= 0;
        udp_checksum_reg <= 0;
        output_ip_hdr_valid_reg <= 0;
        output_eth_dest_mac_reg <= 0;
        output_eth_src_mac_reg <= 0;
        output_eth_type_reg <= 0;
        output_ip_version_reg <= 0;
        output_ip_ihl_reg <= 0;
        output_ip_dscp_reg <= 0;
        output_ip_ecn_reg <= 0;
        output_ip_length_reg <= 0;
        output_ip_identification_reg <= 0;
        output_ip_flags_reg <= 0;
        output_ip_fragment_offset_reg <= 0;
        output_ip_ttl_reg <= 0;
        output_ip_protocol_reg <= 0;
        output_ip_header_checksum_reg <= 0;
        output_ip_source_ip_reg <= 0;
        output_ip_dest_ip_reg <= 0;
        output_ip_payload_tdata_reg <= 0;
        output_ip_payload_tvalid_reg <= 0;
        output_ip_payload_tlast_reg <= 0;
        output_ip_payload_tuser_reg <= 0;
        temp_ip_payload_tdata_reg <= 0;
        temp_ip_payload_tlast_reg <= 0;
        temp_ip_payload_tuser_reg <= 0;
        busy_reg <= 0;
        error_payload_early_termination_reg <= 0;
    end else begin
        state_reg <= state_next;

        frame_ptr_reg <= frame_ptr_next;

        hdr_sum_reg <= hdr_sum_next;

        output_ip_hdr_valid_reg <= output_ip_hdr_valid_next;

        busy_reg <= state_next != STATE_IDLE;

        error_payload_early_termination_reg <= error_payload_early_termination_next;

        // generate valid outputs
        case (state_next)
            STATE_IDLE: begin
                // idle; accept new data
                input_udp_hdr_ready_reg <= 1;
                input_udp_payload_tready_reg <= 0;
                output_ip_payload_tvalid_reg <= 0;
            end
            STATE_WRITE_HEADER: begin
                // write header
                input_udp_hdr_ready_reg <= 0;
                input_udp_payload_tready_reg <= 0;
                output_ip_payload_tvalid_reg <= 1;
            end
            STATE_WRITE_PAYLOAD_IDLE: begin
                // write payload; no data in registers; accept new data
                input_udp_hdr_ready_reg <= 0;
                input_udp_payload_tready_reg <= 1;
                output_ip_payload_tvalid_reg <= 0;
            end
            STATE_WRITE_PAYLOAD_TRANSFER: begin
                // write payload; data in output register; accept new data
                input_udp_hdr_ready_reg <= 0;
                input_udp_payload_tready_reg <= 1;
                output_ip_payload_tvalid_reg <= 1;
            end
            STATE_WRITE_PAYLOAD_TRANSFER_WAIT: begin
                // write payload; data in output and temp registers; do not accept new data
                input_udp_hdr_ready_reg <= 0;
                input_udp_payload_tready_reg <= 0;
                output_ip_payload_tvalid_reg <= 1;
            end
            STATE_WRITE_PAYLOAD_TRANSFER_LAST: begin
                // write last payload word; data in output register; do not accept new data
                input_udp_hdr_ready_reg <= 0;
                input_udp_payload_tready_reg <= 0;
                output_ip_payload_tvalid_reg <= 1;
            end
            STATE_WRITE_PAYLOAD_TRANSFER_WAIT_LAST: begin
                // wait for end of frame; data in output register; read and discard
                input_udp_hdr_ready_reg <= 0;
                input_udp_payload_tready_reg <= 1;
                output_ip_payload_tvalid_reg <= 0;
            end
            STATE_WAIT_LAST: begin
                // wait for end of frame; read and discard
                input_udp_hdr_ready_reg <= 0;
                input_udp_payload_tready_reg <= 1;
                output_ip_payload_tvalid_reg <= 0;
            end
        endcase

        if (store_udp_hdr) begin
            output_eth_dest_mac_reg <= input_eth_dest_mac;
            output_eth_src_mac_reg <= input_eth_src_mac;
            output_eth_type_reg <= input_eth_type;
            output_ip_version_reg <= input_ip_version;
            output_ip_ihl_reg <= input_ip_ihl;
            output_ip_dscp_reg <= input_ip_dscp;
            output_ip_ecn_reg <= input_ip_ecn;
            output_ip_length_reg <= input_udp_length + 20;
            output_ip_identification_reg <= input_ip_identification;
            output_ip_flags_reg <= input_ip_flags;
            output_ip_fragment_offset_reg <= input_ip_fragment_offset;
            output_ip_ttl_reg <= input_ip_ttl;
            output_ip_protocol_reg <= input_ip_protocol;
            output_ip_header_checksum_reg <= input_ip_header_checksum;
            output_ip_source_ip_reg <= input_ip_source_ip;
            output_ip_dest_ip_reg <= input_ip_dest_ip;
            udp_source_port_reg <= input_udp_source_port;
            udp_dest_port_reg <= input_udp_dest_port;
            udp_length_reg <= input_udp_length;
            udp_checksum_reg <= input_udp_checksum;
        end

        if (write_hdr_out) begin
            output_ip_payload_tdata_reg <= write_hdr_data;
            output_ip_payload_tlast_reg <= 0;
            output_ip_payload_tuser_reg <= 0;
        end else if (transfer_in_out) begin
            output_ip_payload_tdata_reg <= input_udp_payload_tdata;
            output_ip_payload_tlast_reg <= input_udp_payload_tlast;
            output_ip_payload_tuser_reg <= input_udp_payload_tuser;
        end else if (transfer_in_temp) begin
            temp_ip_payload_tdata_reg <= input_udp_payload_tdata;
            temp_ip_payload_tlast_reg <= input_udp_payload_tlast;
            temp_ip_payload_tuser_reg <= input_udp_payload_tuser;
        end else if (transfer_temp_out) begin
            output_ip_payload_tdata_reg <= temp_ip_payload_tdata_reg;
            output_ip_payload_tlast_reg <= temp_ip_payload_tlast_reg;
            output_ip_payload_tuser_reg <= temp_ip_payload_tuser_reg;
        end

        if (assert_tlast) output_ip_payload_tlast_reg <= 1;
        if (assert_tuser) output_ip_payload_tuser_reg <= 1;
    end
end

endmodule
