(* Fabric configurations written after the RTL freeze. Same format as Pemu.Bitstream; each one
   is proved against a plain description of what it should compute (test_post_proof.ml). *)

open! Core
open Pemu.Bitstream

(* CAN 2.0 receive de-stuffing. After five equal bits a CAN sender inserts one bit of the other
   value, whatever the value was (a USB-style stuffer only does this after ones); the receiver
   throws it away. All elements step on RX ticks.
   - element 1: its LUT passes the sample through while counting (shown: the rx bit role), its
     flop keeps it, so on the next tick the flop is the previous sample. While not counting it
     holds 1 (recessive): a tick that lands between the start-of-frame edge and the re-alignment
     then cannot make the start-of-frame bit look like the second bit of a run;
   - element 0: "this sample equals the previous one", combinational (element 0's output Le0);
   - elements 2..5: how long the run is. e2 = equal & counting, e(k) = equal & e(k-1), all
     flops; e5 = 1 means the last five samples were equal, so this sample is a stuff bit:
     the drop role. A stuff bit differs from the run, so it starts the next run by itself;
   - element 6: e5's next value, shown as the LUT output: "the next sample will be a stuff
     bit" (the flag role), so firmware knows when a stuff bit follows the CRC;
   - ext2 (FABCTL[0]) = counting: firmware sets it at the start-of-frame edge and clears it
     after the CRC, so idle bus time is never counted as a run.
   Roles: rx bit = 1, drop = 5, flag = 6. Start values: element 1 = 1 (recessive), others 0. *)
let can_rx ~n_le =
  let w = Array.create ~len:n_le empty in
  w.(0) <- word ~on_rx:true ~inputs:[ Ext1; Next ] (fun s prev _ _ -> if s = prev then 1 else 0);
  w.(1) <- word ~on_rx:true ~init:1 ~inputs:[ Ext1; Ext2 ] (fun s counting _ _ -> if counting = 1 then s else 1);
  w.(2) <- word ~on_rx:true ~use_ff:true ~inputs:[ Le0; Ext2 ] (fun eq counting _ _ -> eq land counting);
  for k = 3 to 5 do
    w.(k) <- word ~on_rx:true ~use_ff:true ~inputs:[ Le0; Prev ] (fun eq below _ _ -> eq land below)
  done;
  w.(6) <- word ~on_rx:true ~inputs:[ Le0; Prev2 ] (fun eq e4 _ _ -> eq land e4);
  w
;;

(* HDLC / SDLC transmit (ISO 13239, RFC 1662): a 0 after five 1s inside a frame, never inside a
   flag (0x7E has six 1s). NRZ line. On TX ticks, like the USB configuration but with a rule of
   five and a way to stop: ext2 (FABCTL[0]) = 1 while flags go out.
   - elements 5..1: how many of the last sent bits were 1 (e5: the last one, e1: the last five),
     cleared while ext2 is 1;
   - element 0: hold = five 1s went out (and not sending flags): the shifter keeps the bit for a
     tick and the line sends the stuffed 0;
   - element 7: the line, the bit actually sent (data bit, or 0 while holding).
   Roles: line = 7, hold = 0. *)
let hdlc_tx ~n_le =
  let w = Array.create ~len:n_le empty in
  w.(0) <- word ~inputs:[ Next; Ext2 ] (fun five flags _ _ -> five land (1 - flags));
  w.(5) <- word ~use_ff:true ~inputs:[ Ext0; Le0; Ext2 ] (fun d hold flags _ -> d land (1 - hold) land (1 - flags));
  for k = 1 to 4 do
    w.(k)
    <- word ~use_ff:true ~inputs:[ Ext0; Le0; Next; Ext2 ] (fun d hold above flags ->
         d land (1 - hold) land above land (1 - flags))
  done;
  w.(7) <- word ~inputs:[ Ext0; Le0 ] (fun d hold _ _ -> d land (1 - hold));
  w
;;

(* HDLC receive: on RX ticks, NRZ.
   - element 0: the sample (the rx bit role);
   - elements 1..5: e1 = the last sample was 1, e(k) = this and the k-1 before were all 1, so
     e5 = the last five samples were 1;
   - element 6: drop = five 1s and now a 0: the stuffed bit;
   - element 7: flag = five 1s and now a sixth: a flag (or an abort), reported to the program.
   Roles: rx bit = 0, drop = 6, flag = 7. *)
let hdlc_rx ~n_le =
  let w = Array.create ~len:n_le empty in
  w.(0) <- word ~on_rx:true ~inputs:[ Ext1 ] (fun s _ _ _ -> s);
  w.(1) <- word ~on_rx:true ~use_ff:true ~inputs:[ Ext1 ] (fun s _ _ _ -> s);
  for k = 2 to 5 do
    w.(k) <- word ~on_rx:true ~use_ff:true ~inputs:[ Ext1; Prev ] (fun s below _ _ -> s land below)
  done;
  w.(6) <- word ~on_rx:true ~inputs:[ Ext1; Prev ] (fun s five _ _ -> five land (1 - s));
  w.(7) <- word ~on_rx:true ~inputs:[ Ext1; Prev2 ] (fun s five _ _ -> five land s);
  w
;;

(* Biphase-mark (S/PDIF, IEC 60958; also AES3 and USB PD), on TX ticks at twice the bit rate.
   Every bit cell starts with a transition, and a 1 has another one in the middle. None of the
   configurations the chip was designed with has this coding.
   - element 0: 1 in the first half of a bit (toggles every tick; held at 1 in raw mode);
   - element 2: hold = first half and not raw: the shifter keeps each bit for two ticks;
   - element 1: the line. Its LUT output goes to the pin and its flop keeps the level just sent:
     line = last line XOR (raw ? bit : (first half ? 1 : bit)).
   ext2 (FABCTL[0]) = raw mode, for the preambles, which break the biphase rule on purpose: there
   each shifter bit is one half cell, 1 = a transition. Written as transitions, a preamble is
   the same whatever level the line had before it.
   Roles: line = 1, hold = 2. Start values: element 0 = 1, the line 0. *)
let bmc_tx ~n_le =
  let w = Array.create ~len:n_le empty in
  w.(0) <- word ~use_ff:true ~init:1 ~inputs:[ Self; Ext2 ] (fun first raw _ _ -> if raw = 1 then 1 else 1 - first);
  w.(1)
  <- word ~inputs:[ Ext0; Le0; Self; Ext2 ] (fun d first last raw ->
       let t = if raw = 1 then d else if first = 1 then 1 else d in
       last lxor t);
  w.(2) <- word ~inputs:[ Le0; Ext2 ] (fun first raw _ _ -> first land (1 - raw));
  w
;;

(* An infrared carrier (NEC, RC-5, ...), on TX ticks at twice the carrier frequency.
   - element 0: toggles every tick: the carrier, a square wave at half the tick rate;
   - element 1: the line = carrier AND ext2 (FABCTL[0]): the program turns the carrier on for a
     mark and off for a space at exact times (WAIT time), the fabric makes the 38 kHz;
   - element 2: hold = 1 always, so the one word the program loads is never used up and the
     bit engine keeps showing the line on the pin.
   Roles: line = 1, hold = 2. *)
let ir_carrier ~n_le =
  let w = Array.create ~len:n_le empty in
  w.(0) <- word ~use_ff:true ~inputs:[ Self ] (fun c _ _ _ -> 1 - c);
  w.(1) <- word ~inputs:[ Le0; Ext2 ] (fun c on _ _ -> c land on);
  w.(2) <- word ~inputs:[] (fun _ _ _ _ -> 1);
  w
;;

(* AX.25 transmit (packet radio): HDLC framing as in hdlc_tx, then NRZI, as AX.25 sends it: a 0
   changes the line, a 1 leaves it. Elements 0 to 5 are hdlc_tx's (the rule of five, ext2 = 1
   while flags go out); element 6 is the NRZI line: its LUT output (to the pin) is its flop's
   level, changed when the bit actually sent (data, or the stuffed 0 while holding) is 0, and its
   flop keeps that level. Roles: line = 6, hold = 0. *)
let ax25_tx ~n_le =
  let w = hdlc_tx ~n_le in
  w.(6)
  <- word ~inputs:[ Ext0; Le0; Self ] (fun d hold level _ ->
       let sent = d land (1 - hold) in
       if sent = 1 then level else 1 - level);
  w
;;

(* AX.25 receive: NRZI decoding and HDLC de-stuffing, on RX ticks. There is no room for a flag
   element as well, so the program finds flags itself: six 1s in a row among the kept bits (the 0
   that ends a flag comes after five 1s, so it is dropped like a stuffed one).
   - element 0: the bit, decoded: 1 if the sample is the same as the last one (the rx bit role);
   - element 1: the last sample;
   - elements 2..6: e2 = the last bit was 1, e(k) = it and the k-2 before it were all 1, so
     e6 = the last five bits were 1;
   - element 7: drop = five 1s and now a 0: the stuffed bit.
   Roles: rx bit = 0, drop = 7. *)
let ax25_rx ~n_le =
  let w = Array.create ~len:n_le empty in
  w.(0) <- word ~on_rx:true ~inputs:[ Ext1; Next ] (fun s last _ _ -> if s = last then 1 else 0);
  w.(1) <- word ~on_rx:true ~use_ff:true ~inputs:[ Ext1 ] (fun s _ _ _ -> s);
  w.(2) <- word ~on_rx:true ~use_ff:true ~inputs:[ Le0 ] (fun d _ _ _ -> d);
  for k = 3 to 6 do
    w.(k) <- word ~on_rx:true ~use_ff:true ~inputs:[ Le0; Prev ] (fun d below _ _ -> d land below)
  done;
  w.(7) <- word ~on_rx:true ~inputs:[ Le0; Prev ] (fun d five _ _ -> five land (1 - d));
  w
;;

(* USB low-speed receive: NRZI decoding and de-stuffing, on RX ticks (one tick per bit). A USB
   sender puts a 0 after six 1s; the receiver throws away the bit after six 1s. Six needs one
   more flop than a thermometer of 8 elements has room for, so the run of 1s is counted in
   binary (3 flops for 0 to 7).
   - element 0: the bit, decoded: 1 if the sample is the same as the last one (the rx bit role);
   - element 1: the last sample (its flop; start value 0, the idle J state has D+ low);
   - elements 2, 3, 4: c0, c1, c2 = how many 1s in a row before this bit, cleared by a 0:
     on a 1 the count goes up by one (7 wraps to 0, which only a broken packet reaches);
   - element 5: drop = c2 & c1, shown as its LUT output: the count is 6 (or 7), so this bit
     is a stuffed one. The stuffed bit is a 0, so it clears the count itself.
   Roles: rx bit = 0, drop = 5. *)
let usb_rx ~n_le =
  let w = Array.create ~len:n_le empty in
  w.(0) <- word ~on_rx:true ~inputs:[ Ext1; Next ] (fun s last _ _ -> if s = last then 1 else 0);
  w.(1) <- word ~on_rx:true ~use_ff:true ~inputs:[ Ext1 ] (fun s _ _ _ -> s);
  w.(2) <- word ~on_rx:true ~use_ff:true ~inputs:[ Le0; Self ] (fun d c0 _ _ -> d land (1 - c0));
  w.(3)
  <- word ~on_rx:true ~use_ff:true ~inputs:[ Le0; Self; Prev ] (fun d c1 c0 _ ->
       d land (c1 lxor c0));
  w.(4)
  <- word ~on_rx:true ~use_ff:true ~inputs:[ Le0; Self; Prev; Prev2 ] (fun d c2 c1 c0 ->
       d land (c2 lxor (c1 land c0)));
  w.(5) <- word ~on_rx:true ~inputs:[ Prev; Prev2 ] (fun c2 c1 _ _ -> c2 land c1);
  w
;;
