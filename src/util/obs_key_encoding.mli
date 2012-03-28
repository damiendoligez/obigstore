(*
 * Copyright (C) 2011 Mauricio Fernandez <mfp@acm.org>
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version,
 * with the special exception on linking described in file LICENSE.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *)

(** Order-preserving key encoding. *)

(** This module provides functions that encode/decode values into/from
  * byte sequences while preserving the ordering of the original values, i.e.,
  * given two values [x] and [y] and noting the result of the encoding process
  * [enc x] and [enc y] respectively, then, without loss of generality:
  * * [x = y] implies [enc x = enc y]
  * * [x < y] implies [enc x < enc y]
  *)

type error =
    Unsatisfied_constraint of string
  | Incomplete_fragment of string
  | Bad_encoding of string
  | Unknown_tag of int

exception Error of error * string


(** [(_, 'a, _) codec] is a codec for values of type ['a]. *)
type ('internal, 'a, 'parts) codec

(** Codec for primitive types. *)
type 'a primitive_codec = ('a, 'a, unit) codec

(** Internal type. *)
type ('a, 'b, 'ma, 'mb, 'ta, 'tb) cons =
    ('a, 'ma, 'ta) codec * ('b, 'mb, 'tb) codec

(** {2 Operations} *)

(** {3 Encoding/decoding} *)

(** [encode codec b x] appends to the buffer [b] a byte sequence representing
  * [x] according to the [codec].
  * @raise Error(Unsatisfied_constraint _, _) if [x] doesn't satisfy a
  * constraint imposed by [codec]. *)
val encode : (_, 'a, _) codec -> Obs_bytea.t -> 'a -> unit

(** Similar to {!encode}, but directly returning a string. *)
val encode_to_string : (_, 'a, _) codec -> 'a -> string

(** [decode codec s off len scratch] returns the value corresponding to the byte
  * sequence in [s] starting at [off] and whose length is at most [len].
  * @param scratch scratch buffer that might be used to perform decoding.
  * @raise Invalid_arg if [off], [len] don't represent a valid substring of
  * [s].
  * @raise Error((Incomplete_fragment _ | Bad_encoding _), _) if the byte
  * sequence cannot be decoded correctly. *)
val decode :
  (_, 'a, _) codec -> string -> off:int -> len:int -> Obs_bytea.t -> 'a

(** Similar to {!decode}. *)
val decode_string : (_, 'a, _) codec -> string -> 'a

(** {3 Operations on values.} *)

val pp : (_, 'a, _) codec -> 'a -> string
val min : (_, 'a, _) codec -> 'a
val max : (_, 'a, _) codec -> 'a

(** Saturating successor: returns the max if the value is already the max. *)
val succ : (_, 'a, _) codec -> 'a -> 'a

(** Saturating predecessor: returns the min if the value is already the min. *)
val pred : (_, 'a, _) codec -> 'a -> 'a

(** {4 Operations with immutable prefix.} *)

(** Given a codec [c], if [x'] is the internal n-tuple corresponding to the
  * value [x] according to [c], [min5 c x] returns the value corresponding to
  * an internal n-tuple [x''] where the 4 first elements of [x'] have been
  * preserved, and the 5th and following have been set to their minimum values.
  *
  * E.g., for given a codec
  * [let c = byte *** byte *** byte *** byte *** byte *** byte],
  * [min5 c (0, (1, (2, (3, (4, 5))))) = (0, (1, (2, (3, (0, 0)))))].
  * *)
val min5 :
  ('a * ('b * ('c * ('d * ('e * 'f)))), 'g,
   ('h, 'b * 'i, 'j, 'k, 'l,
    ('m, 'c * 'n, 'o, 'p, 'q,
     ('r, 'd * 's, 't, 'u, 'v,
      ('w, 'e * 'f, 'x, 'y, 'z, ('e, 'f, 'a1, 'b1, 'c1, 'd1) cons) cons)
     cons)
    cons)
   cons)
  codec -> 'g -> 'g

(** Similar to {!min5}, but sets all the values starting from the 4th to their
  * minima. *)
val min4 :
  ('a * ('b * ('c * ('d * 'e))), 'f,
   ('g, 'b * 'h, 'i, 'j, 'k,
    ('l, 'c * 'm, 'n, 'o, 'p,
     ('q, 'd * 'e, 'r, 's, 't, ('d, 'e, 'u, 'v, 'w, 'x) cons) cons)
    cons)
   cons)
  codec -> 'f -> 'f

(** Similar to {!min5}, but sets all the values starting from the 3rd to their
  * minima. *)
val min3 :
  ('a * ('b * ('c * 'd)), 'e,
   ('f, 'b * 'g, 'h, 'i, 'j,
    ('k, 'c * 'd, 'l, 'm, 'n, ('c, 'd, 'o, 'p, 'q, 'r) cons) cons)
   cons)
  codec -> 'e -> 'e

(** Similar to {!min5}, but sets all the values starting from the 2nd to their
  * minima. *)
val min2 :
  ('a * ('b * 'c), 'd,
   ('e, 'b * 'c, 'f, 'g, 'h, ('b, 'c, 'i, 'j, 'k, 'l) cons) cons)
  codec -> 'd -> 'd

val min1 : ('a * 'b, 'c, ('a, 'b, 'd, 'e, 'f, 'g) cons) codec -> 'c -> 'c

val max5 :
  ('a * ('b * ('c * ('d * ('e * 'f)))), 'g,
   ('h, 'b * 'i, 'j, 'k, 'l,
    ('m, 'c * 'n, 'o, 'p, 'q,
     ('r, 'd * 's, 't, 'u, 'v,
      ('w, 'e * 'f, 'x, 'y, 'z, ('e, 'f, 'a1, 'b1, 'c1, 'd1) cons) cons)
     cons)
    cons)
   cons)
  codec -> 'g -> 'g
val max4 :
  ('a * ('b * ('c * ('d * 'e))), 'f,
   ('g, 'b * 'h, 'i, 'j, 'k,
    ('l, 'c * 'm, 'n, 'o, 'p,
     ('q, 'd * 'e, 'r, 's, 't, ('d, 'e, 'u, 'v, 'w, 'x) cons) cons)
    cons)
   cons)
  codec -> 'f -> 'f
val max3 :
  ('a * ('b * ('c * 'd)), 'e,
   ('f, 'b * 'g, 'h, 'i, 'j,
    ('k, 'c * 'd, 'l, 'm, 'n, ('c, 'd, 'o, 'p, 'q, 'r) cons) cons)
   cons)
  codec -> 'e -> 'e
val max2 :
  ('a * ('b * 'c), 'd,
   ('e, 'b * 'c, 'f, 'g, 'h, ('b, 'c, 'i, 'j, 'k, 'l) cons) cons)
  codec -> 'd -> 'd
val max1 : ('a * 'b, 'c, ('a, 'b, 'd, 'e, 'f, 'g) cons) codec -> 'c -> 'c


(*+ {2 Codecs} *)

(** {3} Primitive codecs. *)

val self_delimited_string : string primitive_codec
val stringz : string primitive_codec
val stringz_unsafe : string primitive_codec
val positive_int64 : Int64.t primitive_codec
val byte : int primitive_codec
val bool : bool primitive_codec

(** Similar to {!positive_int64}, but with inverted order relative to the
  * natural order of [Int64.t] values, i.e.,
  * given [f = encode_to_string positive_int64_complement], if [x < y] then
  * [f x > f y]. *)
val positive_int64_complement : Int64.t primitive_codec

(** {3 Composite codecs} *)

(** [custom ~encode ~decode ~pp codec] creates a new codec which operates
  * internally with values of the type handled by [codec], but uses [encode] and
  * [decode] to convert to/from an external type, so that for instance
  * [encode (custom ~encode:enc ~decode:dec ~pp codec) b x]
  * is equivalent to  [encode codec b (enc x)], and
  * [decode_string (custom ~encode:enc ~decode:dec ~pp codec) s] is equivalent
  * to [dec (decode_string codec s)].
  * *)
val custom :
  encode:('a -> 'c) ->
  decode:('c -> 'a) ->
  pp:('a -> string) -> ('b, 'c, 'd) codec -> ('b, 'a, 'd) codec

(** [tuple2 c1 c2] creates a new codec which operates on tuples whose 1st element
  * have the type handled by [c1] and whose 2nd element have the type handled
  * by [c2]. *)
val tuple2 :
  ('a, 'b, 'c) codec ->
  ('d, 'e, 'f) codec ->
  ('a * 'd, 'b * 'e, ('a, 'd, 'b, 'e, 'c, 'f) cons) codec

(** Synonym for {! tuple2}. *)
val ( *** ) :
  ('a, 'b, 'c) codec ->
  ('d, 'e, 'f) codec ->
  ('a * 'd, 'b * 'e, ('a, 'd, 'b, 'e, 'c, 'f) cons) codec

(** [tuple3 c1 c2 c3] creates a codec operating on 3-tuples with the types
  * corresponding to the values handled by codecs [c1], [c2] and [c3].
  * Operates similarly to [c1 *** c2 *** c3], but uses a customized
  * pretty-printer and functions to map/to from the internal representation.
  * *)
val tuple3 :
  ('a, 'b, 'c) codec ->
  ('d, 'e, 'f) codec ->
  ('g, 'h, 'i) codec ->
  ('a * ('d * 'g), 'b * 'e * 'h,
   ('a, 'd * 'g, 'b, 'e * 'h, 'c, ('d, 'g, 'e, 'h, 'f, 'i) cons) cons)
  codec

(** [tuple4 c1 c2 c3 c4] creates a codec operating on 4-tuples with the types
  * corresponding to the values handled by codecs [c1], [c2], [c3] and [c4]. *)
val tuple4 :
  ('a, 'b, 'c) codec ->
  ('d, 'e, 'f) codec ->
  ('g, 'h, 'i) codec ->
  ('j, 'k, 'l) codec ->
  ('a * ('d * ('g * 'j)), 'b * 'e * 'h * 'k,
   ('a, 'd * ('g * 'j), 'b, 'e * ('h * 'k), 'c,
    ('d, 'g * 'j, 'e, 'h * 'k, 'f, ('g, 'j, 'h, 'k, 'i, 'l) cons) cons)
   cons)
  codec

(** [tuple5 c1 c2 c3 c4 c5] creates a codec operating on 5-tuples with the
  * types corresponding to the values handled by codecs [c1], [c2], [c3], [c4]
  * and [c5]. *)
val tuple5 :
  ('a, 'b, 'c) codec ->
  ('d, 'e, 'f) codec ->
  ('g, 'h, 'i) codec ->
  ('j, 'k, 'l) codec ->
  ('m, 'n, 'o) codec ->
  ('a * ('d * ('g * ('j * 'm))), 'b * 'e * 'h * 'k * 'n,
   ('a, 'd * ('g * ('j * 'm)), 'b, 'e * ('h * ('k * 'n)), 'c,
    ('d, 'g * ('j * 'm), 'e, 'h * ('k * 'n), 'f,
     ('g, 'j * 'm, 'h, 'k * 'n, 'i, ('j, 'm, 'k, 'n, 'l, 'o) cons) cons)
    cons)
   cons)
  codec

(** [choice2 label1 c1 label2 c2] creates a codec that
  * handles values of type [`A of a | `B of b] where [a] and [b] are the types
  * of the values handled by codecs [c1] and [c2]. These values are encoded as
  * a one-byte tag (0 for [`A x] values, 1 for [`B x] values) followed by the
  * encoding corresponding to the codec used for that value.
  * [label1] and [label2] are only used in pretty-printing-related function. *)
val choice2 :
  string -> ('a, 'a, 'b) codec ->
  string -> ('c, 'c, 'd) codec ->
  ([ `A of 'a | `B of 'c ], [ `A of 'a | `B of 'c ], unit) codec

(** Refer to {!choice2}. *)
val choice3 :
  string -> ('a, 'a, 'b) codec ->
  string -> ('c, 'c, 'd) codec ->
  string -> ('e, 'e, 'f) codec ->
  ([ `A of 'a | `B of 'c | `C of 'e ], [ `A of 'a | `B of 'c | `C of 'e ],
   unit)
  codec

(** Refer to {!choice2}. *)
val choice4 :
  string -> ('a, 'a, 'b) codec ->
  string -> ('c, 'c, 'd) codec ->
  string -> ('e, 'e, 'f) codec ->
  string -> ('g, 'g, 'h) codec ->
  ([ `A of 'a | `B of 'c | `C of 'e | `D of 'g ],
   [ `A of 'a | `B of 'c | `C of 'e | `D of 'g ], unit)
  codec

(** Refer to {!choice2}. *)
val choice5 :
  string -> ('a, 'a, 'b) codec ->
  string -> ('c, 'c, 'd) codec ->
  string -> ('e, 'e, 'f) codec ->
  string -> ('g, 'g, 'h) codec ->
  string -> ('i, 'i, 'j) codec ->
  ([ `A of 'a | `B of 'c | `C of 'e | `D of 'g | `E of 'i ],
   [ `A of 'a | `B of 'c | `C of 'e | `D of 'g | `E of 'i ], unit)
  codec

