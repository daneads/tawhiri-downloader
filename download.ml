open Core.Std
open Async.Std
open Common

module Urls = struct
  let base_url = "http://www.nomads.ncep.noaa.gov/pub/data/nccf/com/gfs/prod/"
  let string_of_fcst_hour =
    function
    | `h00 -> "00"
    | `h06 -> "06"
    | `h12 -> "12"
    | `h18 -> "18"
  let forecast_dir (date, hr) =
    base_url ^ sprintf "gfs.%Y%m%d/" date ^ string_of_fcst_hour hr

  let grib_file fcst_time levels ~hour =
    let fcst_hr = string_of_fcst_hour (snd fcst_time) in
    let maybe_b =
      match levels with
      | `pgrb2 -> ""
      | `pgrb2b -> "b"
    in
    forecast_dir fcst_time ^ sprintf "gfs.t%sz.pgrb2%s.0p50.f%03i" fcst_hr maybe_b hour

  let index_file fcst_time levels ~hour =
    grib_file fcst_time levels ~hour ^ ".idx"

  let grib_file  fcst_time levels ~hour = Url.of_string (grib_file  fcst_time levels ~hour)
  let index_file fcst_time levels ~hour = Url.of_string (index_file fcst_time levels ~hour)
end

module Axes = struct
  let hours = List.range ~stride:3 ~start:`inclusive ~stop:`inclusive 0 192
  let levels_pgrb2 = 
    [ 10; 20; 30; 50; 70; 100; 150; 200; 250; 300; 350; 400
    ; 450; 500; 550; 600; 650; 700; 750; 800; 850; 900; 925
    ; 950; 975; 1000
    ]
    |> List.map ~f:(fun x -> Level.Mb x)
  let levels_pgrb2b =
    [ 1; 2; 3; 5; 7; 125; 175; 225; 275; 325; 375; 425
    ; 475; 525; 575; 625; 675; 725; 775; 825; 875
    ]
    |> List.map ~f:(fun x -> Level.Mb x)
  let levels =
    (levels_pgrb2 @ levels_pgrb2b)
    |> List.sort ~cmp:(fun (Mb x) (Mb y) -> Int.compare y x)
  let variables = Variable.([Height; U_wind; V_wind])

  let hour_idx i =
    if i mod 3 = 0 && 0 <= i && i <= 192
    then Some (i / 3)
    else None

  let level_idx =
    let module Tbl = Hashtbl.Make(struct
      include Level
      let compare (Mb x) (Mb y) = Int.compare y x
      let hash (Mb x) = Int.hash x
    end) in
    let table =
      List.mapi levels ~f:(fun idx (Level.Mb level) -> (level, idx))
      |> Tbl.of_alist
    in
    Tbl.find

  let variable_idx =
    function
    | Height -> 0
    | U_wind -> 1
    | V_wind -> 2

  let () = List.iteri hours ~f:(fun idx hour -> assert (hour_idx hour = idx))
  let () = List.iteri levels ~f:(fun idx level -> assert (level_idx level = idx))
  let () = List.iteri variables ~f:(fun idx var -> assert (variable_idx var = idx))
end

let throttled_get =
  let throttle = Throttle.create ~continue_on_error:true ~max_concurrent_jobs:5 in
  fun uri ~interrupt ~range ->
    Throttle.enqueue throttle (fun () ->
      Http.get uri ~interrupt ~range
    )

let with_retries ~name ~f ~attempt_timeout ~interrupt =
  let next_backoff x =
    let open Time.Span in 
    if x < of_sec 100.
    then x * 2.
    else x
  in
  let loop ~backoff =
    let interrupt_this = Ivar.create () in
    let res = f ~interrupt:(Ivar.read interrupt_this) () in
    choose
      [ choice res (fun res -> `Res res)
      ; choice (Clock.after attempt_timeout) (fun res -> `Timeout)
      ; choice interrupt (fun res -> `Interrupted)
      ]
    >>= fun res ->
    Ivar.fill interrupt_this ();
    let retry () =
      Clock.after backoff >>= fun () ->
      loop ~backoff:(next_backoff backoff)
    in
    match res with
    | `Res (Ok res) ->
      return (Ok res)
    | `Res (Error err) ->
      Log.Global.debug !"%s %{Error#mach} (backoff %{Time.Span})" name err backoff;
      retry ()
    | `Timeout ->
      Log.Global.debug !"%s Timeout (backoff %{Time.Span})" name backoff;
      retry ()
    | `Interrupted ->
      return (Or_error.error_string "interrupted")
  in
  loop ~backoff:(Time.Span.of_sec 5.)

let check_index_has_all_messages =
  let module M = Map.Make(struct
    type t = Variable.t * Level.t with sexp, compare
  end) in
  let module S = Set.Make(struct
    type t = Variable.t * Level.t with sexp, compare
  end) in
  let expect_vl_a =
    List.cartesian_product Axes.variables Axes.levels_pgrb2
    |> Set.of_list
  in
  let expect_vl_b =
    List.cartesian_product Axes.variables Axes.levels_pgrb2b
    |> Set.of_list
  in
  let expect_vl =
    function
    | `pgrb2  -> expect_vl_a
    | `pgrb2b -> expect_vl_b
  in
  fun messages ~expect_levels ~expect_hour ~expect_fcst_time ->
    let open Result.Monad_infix in
    let expect_vl = expect_vl expect_levels in
    let rec loop messages present =
      match messages with
      | [] -> Ok present
      | msg:: messages ->
        let { Grib_index.offset = _; length = _; fcst_time; variable; level; hour } = msg in
        let key = (variable, level) in
        if fcst_time <> expect_fcst_time || hour <> expect_hour
        then
          Error.errorf
            !"Index (fcst time, hour) = (%{Forecast_time}, %i); expected (%{Forecast_time}, %i)"
            fcst_time hour expect_fcst_time expect_hour
        else if M.mem present key
        then
          Error.errorf !"Duplicate message in index (%{Variable}, %{Level})" variable level
        else if not (S.mem expect_vl key)
        then
          loop messages present
        else
          loop messages (M.add present ~key ~data:msg)
    in
    loop messages >>= fun present ->
    if M.length present <> S.length expect_vl
    then Ok present
    else Error.error_string "Messages missing from index"

let get_index ~interrupt fcst_time levels ~hour =
  with_retries
    ~name:(
      sprintf
        !"IDX %{Forecast_time} %{Sexp} %i"
        fcst_time (<:sexp_of< [ `pgrb | `pgrb2 ] >>) levels hour
    )
    ~interrupt ~attempt_timeout:(Time.Span.of_sec 10.)
    ~f:(fun ~interrupt () ->
      throttled_download
        (Urls.index_file fcst_time levels ~hour)
        ~range:(`all_with_max_len (32 * 1024))
        ~interrupt
      >>|?| Bigstring.to_string
      >>|?= Grib_index.parse
      >>|?=
        check_index_has_all_messages 
          ~expect_levels:levels
          ~expect_fcst_time:fcst_time
          ~expect_hour:hour
    )

let get_message ~interrupt (msg : Grib_index.message) =
  with_retries
    ~name:(Grib_message.message_to_string msg)
    ~interrupt ~attempt_timeout:(Time.Span.of_sec 60.)
    ~f:(fun ~interrupt () ->
      throttled_download
        (Urls.grib_file msg.fcst_time levels ~hour)
        ~range:(`exactly_pos_len (msg.offset, msg.length))
        ~interrupt
      >>|?= Grib_message.of_bigstring
      >>|?= fun message ->
      let matches =
           Grib_message.variable = Ok msg.variable
        && Grib_message.hour     = Ok msg.hour
        && Grib_message.level    = Ok msg.level
        && Grib_message.layout   = Ok msg.layout
      in
      if matches
      then Ok message
      else Error.errorf "GRIB message contents did not match index"
    )
