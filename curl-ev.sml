structure CurlEv :
sig
  type ev
  type multi
  type easy
  val curl_ev: ev -> multi -> (easy * (easy * int -> unit) * int) -> unit
end =
struct
  exception CurlEv of string
  open CurlConst Curl
  open EvWithTimer
  structure H = HashArrayLargeInt
  type easy = Easy.curl
  type multi = Multi.multi

  fun curl_ev ev multi =
    let
      val hash_size = 100
      val finishH = H.hash hash_size (* easy_int => finish *)
      val timerH  = H.hash hash_size (* easy_int => int *)

      val multi_active = ref ~1

      fun socket_action(socket, ev_bitmask) =
        let
          val active = Multi.socket_action(multi, socket, ev_bitmask)

          fun info_read () =
            let
              fun doFinish easy result =
                let 
                  val easy_int = Multi.easy2int easy
                  val finish = valOf(H.sub(finishH, easy_int))
                in 
                  H.delete(timerH, easy_int);
                  H.delete(finishH, easy_int);
                  finish(easy, result)
                end
            in
              case Multi.info_read(multi) of
                   NONE => ()
                 | SOME (msg, easy, result) =>
                     if msg = CURLMSG_DONE 
                     then (doFinish easy result; info_read () )
                     else raise (CurlEv ("I don't know what to do with message: " ^ Int.toString(msg)))
            end
           
        in
          if (!multi_active) = active then () else ( multi_active := active; info_read () )
        end


      fun cb_timeout () = socket_action(CURL_SOCKET_TIMEOUT, 0)

      val add_handle_timer_id = evTimerNew ev

      fun add_handle(easy, finish:(Curl.Easy.curl * int -> unit), timeout) =
        let
          val easy_int = Multi.easy2int easy
          val _ = H.update(finishH, easy_int, finish)

          fun cb_big_timeout () =
            case H.sub(timerH, easy_int) of
                 NONE => ()
               | SOME timer_id => 
                 (
                    evTimerDelete ev timer_id;
                    H.delete(timerH, easy_int);
                    Multi.remove_handle(multi, easy);
                    valOf(H.sub(finishH, easy_int)) (easy:Curl.Easy.curl, CURLE_COULDNT_CONNECT);
                    H.delete(finishH, easy_int)
                  )

        in
          Multi.add_handle(multi, easy);
          evTimerAdd ev (add_handle_timer_id, Time.fromMilliseconds 1, cb_timeout);

          if timeout = 0 then () else 
          let 
            val timer_id = evTimerNew ev
          in
            evTimerAdd ev (timer_id, Time.fromSeconds(Int.toLarge timeout), cb_big_timeout );
            H.update(timerH, easy_int, timer_id)
          end
        end


      val timerId = evTimerNew ev
      val timerLoopVal = ref (Time.fromMilliseconds 1)
      fun timerLoop () = evTimerAdd ev (timerId, (!timerLoopVal), fn () => ( cb_timeout ();  timerLoop () ))

      fun cb_timer(multi, timeout_ms) = (
        if timeout_ms < 0
        then ( timerLoopVal := Time.fromSeconds 10 )
        else ( timerLoopVal := Time.fromMilliseconds (Int.toLarge timeout_ms); timerLoop () )
        ; 1)


      fun cb_socket(easy, socket, poll) = (
        if poll = CURL_POLL_IN orelse poll = CURL_POLL_INOUT
        then evModify ev [evAdd (socket, evRead, (fn (_,_) => socket_action(socket, CURL_CSELECT_IN) ))]
        else evModify ev [evDelete (socket, evRead)]
        ;
        if poll = CURL_POLL_OUT orelse poll = CURL_POLL_INOUT
        then evModify ev [evAdd (socket, evWrite, (fn (_,_) => socket_action(socket, CURL_CSELECT_OUT) ))]
        else evModify ev [evDelete (socket, evWrite)]
        ; 1)


    in
      Multi.setopt_socket_cb(multi, cb_socket);
      Multi.setopt_timer_cb(multi, cb_timer);
      timerLoop();
      add_handle
    end
end
