(***********************************************************************)
(*                                                                     *)
(*                           Objective Caml                            *)
(*                                                                     *)
(*  Xavier Clerc, Luc Maranget, projet Moscova, INRIA Rocquencourt     *)
(*                                                                     *)
(*  Copyright 2010 Institut National de Recherche en Informatique et   *)
(*  en Automatique.  All rights reserved.  This file is distributed    *)
(*  under the terms of the Q Public License version 1.0.               *)
(*                                                                     *)
(***********************************************************************)

module type Config = sig
  val debug : bool
  val nagain : int
end

module Make(C:Config) (E:Iterator.S) = struct

type ('partial, 'result) t = {
  register : (E.elt -> 'partial) Join.chan;
  fold : E.t -> ('partial -> 'result -> 'result) -> 'result -> 'result;
}


type key = int

type ('b,'c) monitor =
  { enter : E.elt -> key ;
    leave : key * 'b -> unit ;
    is_active : key -> bool ;
    get_active : unit -> (key * E.elt) list ;
    wait : unit -> 'c ;
    finished : unit Join.chan }

let rec to_string = function
  | [] -> ""
  | [x,_] -> string_of_int x
  | (x,_)::rem ->  string_of_int x ^ ", " ^ to_string rem

let create_monitor gather default =
  def state(new_id, active, result) & enter(x) =
    state(new_id+1, (new_id,x)::active, result) &
    reply new_id to enter

  or state(new_id, active, result) & leave(id,v) =
    reply to leave &
    if List.mem_assoc id active then
      let result' = gather v result in
      let active'= List.remove_assoc id active in
      state(new_id, active', result')
    else
      state(new_id, active, result)

  or state(new_id, active, result) & is_active(id) =
    state(new_id, active, result) &
    let b = List.mem_assoc id active in
    reply b to is_active

  or state(new_id, active, result) & get_active() =
    if C.debug then
      Join.debug "DIST" "Get %s" (to_string active) ;
    state(new_id, active, result) &
    reply active to get_active

  or state(new_id, [], result) & wait() & finished() =
    state(new_id, [], result) & reply result to wait

  in spawn state(0, [], default) ;

  {  enter=enter ; leave=leave ;
     is_active=is_active ;
     get_active=get_active ;
     wait=wait; finished=finished ; }

  type 'a queue = E | Q of ('a list * 'a list)

  let put c q = match q with
  | E -> Q ([c],[])
  | Q (xs,ys) -> Q (xs,c::ys)

  and put_front c q = match q with
  | E -> Q ([c],[])
  | Q (xs,ys) -> Q (c::xs,ys)

  let rec get = function
    | ([c],[])|([],[c]) -> c,E
    | (x::xs,ys) -> x,Q (xs,ys)
    | ([],(_::_ as ys)) -> get (List.rev ys,[])
    | ([],[]) -> assert false

  let create () =

    def pool(high,low) & addPool(c) = pool(put c high,low)

    or pool(Q high,low) & agent(worker) =
      let (monitor,enum),high = get high in
      match E.step enum with
      | Some (x,next) ->
          let id = monitor.enter(x) in
          pool(put (monitor,next) high,low) &
          call_worker(monitor, id, x, worker)
      | None ->
          agent(worker) &
          monitor.finished() &
          pool(high,put ([],C.nagain,monitor) low)


  (* Re-perform tasks *)
   or pool(E,Q low) & agent(worker) =
       let (xs,n,m),low = get low in
       match xs with 
       | (id,x)::xs ->
           pool (E,put_front (xs,n,m) low) &
           begin if m.is_active id then
              call_worker(m,id,x,worker)
           else
             agent(worker)
           end
       | [] ->
          agent(worker) &
	  if n > 0 then begin
	    let again = m.get_active () in
	    match again with
            | [] ->
               pool(E,low)
            | _  ->
               pool(E,put (again,n-1,m) low)
          end else begin
            pool(E,low)
          end

   or compute(monitor,id,x) & agent(worker) =
         call_worker(monitor,id,x,worker)

  and call_worker(monitor,id,x,worker) =
    let r = try Some (worker x) with _ -> None in
    match r with
    | None -> compute(monitor,id,x)
    | Some v ->
        monitor.leave(id,v) ;
        agent(worker)

  in
  spawn pool(E,E) ;
  let fold sc gather default =
    let monitor = create_monitor gather default in
    spawn addPool(monitor, E.start sc) ;
    monitor.wait ()

  in
  { fold = fold ; register = agent ; }

end
