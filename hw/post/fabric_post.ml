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
