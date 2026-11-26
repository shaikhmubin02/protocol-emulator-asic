(* Print a fabric configuration's eight words in hex, one a line, for tests that load it through
   the host port as a board would (test/test.py):  fabric_words.exe can_rx *)
open! Core

let () =
  let n_le = Pemu.Model.n_le in
  let module F = Pemu_post.Fabric_post in
  let configs =
    [ "can_rx", F.can_rx
    ; "hdlc_tx", F.hdlc_tx
    ; "hdlc_rx", F.hdlc_rx
    ; "bmc_tx", F.bmc_tx
    ; "ir_carrier", F.ir_carrier
    ; "ax25_tx", F.ax25_tx
    ; "ax25_rx", F.ax25_rx
    ; "usb_rx", F.usb_rx
    ; "usb_tx", Pemu.Bitstream.usb_tx
    ]
  in
  match Sys.get_argv () with
  | [| _; name |] ->
    (match List.Assoc.find configs name ~equal:String.equal with
     | Some f -> Array.iter (f ~n_le) ~f:(fun w -> printf "%08x\n" w)
     | None -> failwithf "no configuration %s" name ())
  | _ -> failwith "usage: fabric_words.exe <configuration>"
;;
