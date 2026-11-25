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
