(* Generic count (from Hillerström et al. (2020)) *)

module List = struct
  include List
  let sum = List.fold_left (+) 0
end

module type GENERIC_COUNT = sig
  val name : string
  val count : ((int -> bool) -> bool) -> int
end

module Handlers_count = struct
  let name = "handlers count"
  type _ Effect.t += Branch : bool Effect.t

  let count f =
    Effect.Deep.match_with f (fun _ -> Effect.perform Branch)
      Effect.Deep.({ retc = (fun x -> if x then 1 else 0)
                  ; exnc = raise
                  ; effc = (fun (type a) (eff : a Effect.t) ->
                    match eff with
                    | Branch ->
                       Some (fun (k : (a, _) continuation) ->
                           let open Multicont.Deep in
                           let r = promote k in
                           let tt = resume r true in
                           let ff = resume r false in
                           tt + ff)
                    | _ -> None) })
end

module Callcc_count = struct
  let name = "callcc count"

  let count f =
    let open Libctrl.Callcc in
    (* NOTE: Sys.opaque_identity is a trick to prevent the compiler
       from performing the heap-to-stack conversion optimisation,
       which is invalid in the presence of multi-shot
       continuations. *)
    let result = Sys.opaque_identity (ref 0) in
    let cc = Sys.opaque_identity (ref (fun _x -> false)) in
    let pop k = cc := k in
    let push k =
      (* Memoise the previous continuation function. *)
      let prev = !cc in
      (* Override the continuation function to be a wrapper around the
         current continuation `k`. *)
      cc := (fun x -> (* the following trick realises the "back up"
                         behaviour of multi-shot delimited
                         continuations. It restores the previous
                         continuation function such the rest of the
                         program sees it after the exploration of the
                         false branch using the current
                         continuation. *)
        if x then k x else (pop prev; k x))
    in
    (* We install the prompt here to delimit the effects of
       `callcc'. *)
    prompt (fun () ->
        let () =
          if f (fun _i ->
                 callcc (fun k ->
                     push (throw k);
                     !cc true))
          then incr result else ()
        in
        ignore (!cc false);
        !result)
end

module Amb_count = struct
  let name = "amb count"

  let count f =
    let open Libctrl.Amb in
    List.sum (collect
                (fun () ->
                  if f (fun _ -> amb [true; false]) then 1 else 0))
end

module Reflection_count = struct
  let name = "reflection count"

  open Libctrl.Monadic_reflection

  module ListM = struct
    type 'a t = 'a list

    let return : 'a. 'a -> 'a t
      = fun x -> [x]

    let (>>=) : 'a 'b. 'a t -> ('a -> 'b t) -> 'b t
      = fun m k -> List.flatten (List.map k m)

    let choose : 'a. 'a list -> 'a t
      = fun xs ->
      xs >>= return
  end

  module ListR = Make(ListM)

  let choose xs = ListR.reflect (ListM.choose xs)

  let count f =
    List.sum (ListR.reify (fun () ->
                  if f (fun _ -> choose [true; false]) then 1 else 0))
end

module Shift_reset_count = struct
  let name = "shift/reset count"

  let count f =
    let open Libctrl.Shift_reset in
    reset (fun p ->
        if f (fun _ ->
               shift p (fun k ->
                   let tt = resume k true in
                   let ff = resume k false in
                   tt + ff))
        then 1 else 0)
end

let counters : (module GENERIC_COUNT) list =
  [ (module Handlers_count)
  ; (module Callcc_count)
  ; (module Amb_count)
  ; (module Reflection_count)
  ; (module Shift_reset_count) ]

let bxor x y =
  (x || y) && not (x && y)

let xor_list (xs : bool list) =
  List.fold_left bxor false xs

let xor (n : int) (q : (int -> bool)) =
  xor_list (List.init n q)

let rec pow a = function
  | 0 -> 1
  | 1 -> a
  | n ->
     let b = pow a (n / 2) in
     b * b * (if n mod 2 = 0 then 1 else a)

let qcheck_tests =
  let xor_tests =
    List.map (fun (module G : GENERIC_COUNT) ->
        QCheck.(Test.make ~count:50 ~name:G.name
          (int_range 0 20)
          (fun n ->
            let ans = (pow 2 n) / 2 in
            Int.equal ans (G.count (xor n)))))
      counters
  in
  xor_tests

let ounit2_tests =
  let open OUnit2 in
  "test suite for generic count" >:::
    List.map QCheck_ounit.to_ounit2_test qcheck_tests

let _ = OUnit2.run_test_tt_main ounit2_tests
