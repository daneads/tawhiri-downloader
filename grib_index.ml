open Core.Std
open Common

type line = 
  { idx : int
  ; offset : int
  ; fcst_time : Forecast_time.t
  ; variable : Variable.t
  ; level : Level.t
  ; hour : int
  }

type message =
  { offset : int
  ; length : int
  ; fcst_time : Forecast_time.t
  ; variable : Variable.t
  ; level : Level.t
  ; hour : int
  }

let message_of_string { offset; length; fcst_time; variable; level; hour } =
  sprintf
    !"%{Forecast_time} %{Variable} %{Level} %i (%i;%i)"
    fcst_time variable level hour offset length

let drop_suffix ~suffix s =
  if String.is_suffix ~suffix s
  then Ok (String.subo ~len:(String.length s - String.length suffix) s)
  else Or_error.errorf "expected suffix %s in %s" suffix s

let int_of_string s = Or_error.try_with (fun () -> Int.of_string s)

let parse_variable =
  function
  | "HGT" -> Ok Variable.Height
  | "UGRD" -> Ok Variable.U_wind
  | "VGRD" -> Ok Variable.V_wind
  | other -> Or_error.errorf "couldn't identify variable %s" other

let parse_hour =
  let open Result.Monad_infix in
  function
  | "anl" -> Ok 0
  | hour ->
    drop_suffix hour ~suffix:" hour fcst" >>= fun hour ->
    int_of_string hour >>= fun hour ->
    if hour mod 3 = 0
    then Ok hour
    else Or_error.errorf "hour %i" hour

let parse_fcst_time s =
  if String.length s <> 12
  then Or_error.error_string "fcst time length"
  else
    Or_error.try_with (fun () ->
      let date = Date.of_string (String.sub s ~pos:2 ~len:8) in
      let hour =
        match String.sub s ~pos:10 ~len:2 with
        | "00" -> `h00
        | "06" -> `h06
        | "12" -> `h12
        | "18" -> `h18
        | _ -> failwith "hour"
      in
      (date, hour)
    )

let parse_level s =
  let open Result.Monad_infix in
  drop_suffix ~suffix:" mb" s
  >>= int_of_string
  >>| (fun x -> Level.Mb x)

(* 15:1207405:d=2015080106:CLWMR:2 mb:159 hour fcst: *)
let parse_line =
  let open Result.Monad_infix in
  function
  | [idx; offset; fcst_time; variable; level; hour; ""] ->
    int_of_string offset >>= fun offset ->
    int_of_string idx >>= fun idx ->
    parse_fcst_time fcst_time >>= fun fcst_time ->
    parse_variable variable >>= fun variable ->
    parse_level level >>= fun level ->
    parse_hour hour >>= fun hour ->
    Ok { idx; offset; fcst_time; variable; level; hour }
  | _ -> Or_error.error_string "malformed line"

let parse_idx_offset =
  let open Result.Monad_infix in
  function
  | idx::offset::_ ->
    int_of_string idx >>= fun idx ->
    int_of_string offset >>= fun offset ->
    Ok (idx, offset)
  | _ -> Or_error.of_string "malformed line"

let parse index =
  let open Result.Monad_infix in
  let rec loop parsed_lines input_lines =
    match input_lines with
    | x::(y::_ as xs) ->
      begin
        match parse_line x with
        | Ok { idx; offset; fcst_time; variable; level; hour } ->
          parse_idx_offset y >>= fun (next_idx, next_offset) ->
          let length = next_offset - offset in
          if next_idx = idx + 1 && length > 0
          then loop ({ offset; length; fcst_time; variable; level; hour } :: parsed_lines) xs
          else Or_error.errorf "line after %i made no sense" idx
        | Error _ ->
          (* didn't recognise this line; don't care. *)
          loop parsed_lines xs
      end
    | [x] ->
      begin
        match parse_line x with
        | Ok _ -> Or_error.error_string "not implemented: line we care about at end of file"
        | Error _ -> Ok parsed_lines
      end
    | [] -> Ok parsed_lines
  in
  String.split_lines index
  |> List.map ~f:(String.split ~on:':')
  |> loop []
