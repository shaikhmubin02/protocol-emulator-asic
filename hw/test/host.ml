(* A test-side host: queues words for the engine and hands them over when the engine's inbox
   has room, like the real host checking the mailbox status over SPI. *)

open! Core
open Pemu

type t =
  { pending : int Queue.t
  ; received : int Queue.t
  }

let create words = { pending = Queue.of_list words; received = Queue.create () }

(* Call once per cycle, after Model.step. *)
let service t m =
  (match Queue.peek t.pending with
   | Some w -> if Model.host_send m w then ignore (Queue.dequeue_exn t.pending : int)
   | None -> ());
  Option.iter (Model.host_receive m) ~f:(Queue.enqueue t.received)
;;

let received t = Queue.to_list t.received
