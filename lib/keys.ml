
open Rresult.R.Infix

let src = Logs.Src.create "awa.authenticator" ~doc:"AWA authenticator"
module Log = (val Logs.src_log src : Logs.LOG)

type typ = [ `Rsa | `Ed25519 ]

let typ_of_string s =
  match String.lowercase_ascii s with
  | "rsa" -> Ok `Rsa
  | "ed25519" -> Ok `Ed25519
  | _ -> Error ("unknown key type " ^ s)

type authenticator = [
  | `No_authentication
  | `Key of Hostkey.pub
  | `Fingerprint of typ * string
]

let hostkey_matches a key =
  match a with
  | `No_authentication ->
    Log.warn (fun m -> m "NO AUTHENTICATOR");
    true
  | `Key pub' ->
    if key = pub' then begin
      Log.app (fun m -> m "host key verification successful!");
      true
    end else begin
      Log.err (fun m -> m "host key verification failed");
      false
    end
  | `Fingerprint (typ, s) ->
    let hash = Mirage_crypto.Hash.SHA256.digest (Wire.blob_of_pubkey key) in
    Log.app (fun m -> m "authenticating server fingerprint SHA256:%s"
                (Base64.encode_string ~pad:false (Cstruct.to_string hash)));
    let typ_matches = match typ, key with
      | `Ed25519, Hostkey.Ed25519_pub _ -> true
      | `Rsa, Hostkey.Rsa_pub _ -> true
      | _ -> false
    and fp_matches = Cstruct.(equal (of_string s) hash)
    in
    if typ_matches && fp_matches then begin
      Log.app (fun m -> m "host fingerprint verification successful!");
      true
    end else begin
      Log.err (fun m -> m "host fingerprint verification failed");
      false
    end

let authenticator_of_string str =
  if str = "" then
    Ok `No_authentication
  else
    match Astring.String.cut ~sep:":" str with
    | Some (y, fp) ->
      (match y with
       | "SHA256" -> Ok `Rsa
       | y -> typ_of_string y) >>= fun t ->
      begin match Base64.decode ~pad:false fp with
        | Error (`Msg m) ->
          Error ("invalid authenticator (bad b64 in fingerprint): " ^ m)
        | Ok fp -> Ok (`Fingerprint (t, fp))
      end
    | _ ->
      match Base64.decode ~pad:false str with
      | Ok k ->
        (Wire.pubkey_of_blob (Cstruct.of_string k) >>| fun key ->
         `Key key)
      | Error (`Msg msg) ->
        Error (str ^ " is invalid or unsupported authenticator, b64 failed: " ^ msg)

let of_seed typ seed =
  let g =
    let seed = Cstruct.of_string seed in
    Mirage_crypto_rng.(create ~seed (module Fortuna))
  in
  match typ with
  | `Rsa ->
    let key = Mirage_crypto_pk.Rsa.generate ~g ~bits:2048 () in
    let public = Mirage_crypto_pk.Rsa.pub_of_priv key in
    let pubkey = Wire.blob_of_pubkey (Hostkey.Rsa_pub public) in
    Log.info (fun m -> m "using ssh-rsa %s"
                 (Cstruct.to_string pubkey |> Base64.encode_string));
    Hostkey.Rsa_priv key
  | `Ed25519 ->
    let key = Hacl_ed25519.priv (Mirage_crypto_rng.generate ~g 32) in
    let public = Hacl_ed25519.priv_to_public key in
    let pubkey = Wire.blob_of_pubkey (Hostkey.Ed25519_pub public) in
    Log.info (fun m -> m "using ssh-ed25519 %s"
                 (Cstruct.to_string pubkey |> Base64.encode_string));
    Hostkey.Ed25519_priv key
