(* PS/2 (keyboard and mouse port), written from the protocol's description: two open-drain lines,
   CLK and DATA, pulled high, so each line is low if either side pulls it. The device makes the
   clock. Device to host: start (0), 8 bits LSB first, odd parity, stop (1), the host reading
   DATA as CLK falls; the host can hold CLK low to stop the device. Host to device: the host holds
   CLK low for 100 us, pulls DATA low and lets CLK go; the device clocks in 8 bits, parity and
   stop (the host changes DATA while CLK is low) and acknowledges by pulling DATA low for one more
   clock. *)
open! Core

let odd_parity b = 1 - (Int.popcount (b land 0xFF) land 1)

(* the computer's side *)
module Host = struct
  type action =
    | Send of int * int (* at, byte *)
    | Inhibit of int * int (* from, until *)

  type t =
    { mutable clk : int (* what this side does to the line: 1 = lets go *)
    ; mutable data : int
    ; mutable last_clk : int
    ; mutable bits : int list (* bits read so far, newest first *)
    ; mutable last_fall : int
    ; mutable received : (int * bool) list (* newest first: byte, frame right *)
    ; mutable sending : int list option (* bits still to set, then the acknowledge clock *)
    ; mutable acks : bool list
    ; mutable actions : action list
    ; mutable falls : int list (* when CLK fell, newest first: for the clock rate *)
    ; hold_after : int option (* hold CLK low this long after each byte read, as hosts may *)
    ; mutable holding : (int * int) option
    }

  let create ?hold_after actions =
    { clk = 1
    ; data = 1
    ; last_clk = 1
    ; bits = []
    ; last_fall = 0
    ; received = []
    ; sending = None
    ; acks = []
    ; actions
    ; falls = []
    ; hold_after
    ; holding = None
    }
  ;;

  let step t ~cycle ~clk ~data =
    (* scheduled actions *)
    List.iter t.actions ~f:(function
      | Send (at, b) ->
        if cycle = at
        then (
          t.clk <- 0;
          t.bits <- [] (* a byte the host cut off is dropped *));
        if cycle = at + 5000 then t.data <- 0 (* after 100 us: the start bit *);
        if cycle = at + 5050
        then (
          t.clk <- 1;
          t.sending <- Some (List.init 8 ~f:(fun k -> (b lsr k) land 1) @ [ odd_parity b; 1 ]))
      | Inhibit (from, until) ->
        if cycle = from
        then (
          t.clk <- 0;
          t.bits <- []);
        if cycle = until then t.clk <- 1);
    Option.iter t.holding ~f:(fun (from, until) ->
      if cycle = from then t.clk <- 0;
      if cycle = until
      then (
        t.clk <- 1;
        t.holding <- None));
    let fell = clk = 0 && t.last_clk = 1 in
    t.last_clk <- clk;
    if fell then t.falls <- cycle :: t.falls;
    match t.sending with
    | Some (b :: rest) when fell ->
      t.data <- b;
      t.sending <- Some rest
    | Some [] when fell ->
      (* the acknowledge clock *)
      t.acks <- (data = 0) :: t.acks;
      t.data <- 1;
      t.sending <- None
    | Some _ -> ()
    | None ->
      if fell && t.clk = 1
      then (
        if cycle - t.last_fall > 100_000 then t.bits <- [] (* 2 ms of nothing: start over *);
        t.last_fall <- cycle;
        t.bits <- data :: t.bits;
        if List.length t.bits = 11
        then (
          let b = List.rev t.bits in
          let byte = List.foldi (List.sub b ~pos:1 ~len:8) ~init:0 ~f:(fun k a x -> a lor (x lsl k)) in
          let good =
            List.nth_exn b 0 = 0 && List.nth_exn b 10 = 1 && List.nth_exn b 9 = odd_parity byte
          in
          t.received <- (byte, good) :: t.received;
          t.bits <- [];
          Option.iter t.hold_after ~f:(fun d -> t.holding <- Some (cycle + 3500, cycle + 3500 + d))))
  ;;
end

(* a keyboard: it makes the clock (a quarter period [q] cycles) and answers commands *)
module Keyboard = struct
  type state =
    | Idle of int (* since *)
    | Tx of { bits : int array; t0 : int; byte : int }
    | Rx of { t0 : int; mutable got : int list }

  type t =
    { q : int
    ; mutable clk : int
    ; mutable data : int
    ; mutable queue : int list
    ; mutable state : state
    ; mutable commands : (int * bool) list (* newest first *)
    ; mutable aborted : int
    }

  let create ~q ~sends = { q; clk = 1; data = 1; queue = sends; state = Idle 0; commands = []; aborted = 0 }

  let reply t byte ~good =
    let r =
      if not good
      then [ 0xFE ]
      else (
        match byte with
        | 0xFF -> [ 0xFA; 0xAA ]
        | 0xF2 -> [ 0xFA; 0xAB; 0x83 ]
        | 0xEE -> [ 0xEE ]
        | _ -> [ 0xFA ])
    in
    t.queue <- r @ t.queue
  ;;

  let step t ~cycle ~clk ~data =
    let q = t.q in
    match t.state with
    | Idle since ->
      if clk = 1 && data = 0
      then t.state <- Rx { t0 = cycle + q; got = [] } (* the host wants to send *)
      else if clk = 0 || data = 0
      then t.state <- Idle cycle
      else if cycle - since >= 3 * q
      then (
        match t.queue with
        | byte :: rest ->
          t.queue <- rest;
          let bits =
            Array.of_list ((0 :: List.init 8 ~f:(fun k -> (byte lsr k) land 1)) @ [ odd_parity byte; 1 ])
          in
          t.state <- Tx { bits; t0 = cycle + 1; byte } (* from the next cycle: phase 0 sets the start bit *)
        | [] -> ())
    | Tx { bits; t0; byte } ->
      let k = (cycle - t0) / (4 * q)
      and ph = (cycle - t0) % (4 * q) in
      if k >= 11
      then (
        t.data <- 1;
        t.state <- Idle cycle)
      else if ph = 0
      then t.data <- bits.(k)
      else if ph = q
      then t.clk <- 0
      else if ph = 3 * q
      then t.clk <- 1
      else if ph = (3 * q) + 10 && clk = 0
      then (
        (* the host holds CLK low: stop, and send the byte again later *)
        t.data <- 1;
        t.aborted <- t.aborted + 1;
        t.queue <- byte :: t.queue;
        t.state <- Idle cycle)
    | Rx r ->
      let k = (cycle - r.t0) / (4 * q)
      and ph = (cycle - r.t0) % (4 * q) in
      if cycle >= r.t0
      then
        if k < 10
        then (
          if ph = 0 then t.clk <- 0;
          if ph = 2 * q then t.clk <- 1;
          if ph = 3 * q then r.got <- data :: r.got)
        else if k = 10
        then (
          if ph = 0
          then (
            t.data <- 0;
            t.clk <- 0);
          if ph = 2 * q then t.clk <- 1;
          if ph = 3 * q then t.data <- 1)
        else (
          let b = List.rev r.got in
          let byte = List.foldi (List.take b 8) ~init:0 ~f:(fun k a x -> a lor (x lsl k)) in
          let good = List.nth_exn b 8 = odd_parity byte && List.nth_exn b 9 = 1 in
          t.commands <- (byte, good) :: t.commands;
          reply t byte ~good;
          t.state <- Idle cycle)
  ;;
end
