(* (c) 2017 Hannes Mehnert, all rights reserved *)

(** ASN.1 encoding of resources and configuration *)

(** Object Identifiers *)

module Oid : sig

  (** {1 Object identifiers} *)

  (** OIDs in the Mirage namespace (enterprise arc 1.3.6.1.4.1.49836.42) *)

  (** [version] specifies an [INTEGER] describing the version. *)
  val version : Asn.OID.t

  (** {2 OIDs used in delegation certificates} *)

  (** [vms] is an [INTEGER] denoting the number of virtual machines. *)
  val vms : Asn.OID.t

  (** [bridges] is a [CHOICE] between [ [0] UTF8STRING], describing an internal
      bridge, and a [ [1] SEQUENCE] of [UTF8STRING], [IPV4ADDRESS] denoting the first
      IP to use, [IPV4ADDRESS] denoting the last IP to use, [IPV4ADDRESS]
      denoting the default gateway, [INTEGER] denoting the netmask. *)
  val bridges : Asn.OID.t

  (** [block] is an [INTEGER] denoting the size of block storage available for
      this delegation in MB. *)
  val block : Asn.OID.t

  (** [cpuids] is a [SEQUENCE OF INTEGER] denoting the CPU identifiers available
      for this delegate. *)
  val cpuids : Asn.OID.t

  (** [memory] is an [INTEGER] denoting the amount of available memory, in
      MB.  Also used in virtual machine certificates. *)
  val memory : Asn.OID.t

  (** {2 OIDs used in virtual machine certificates} *)

  (** [cpuid] is an [INTEGER] denoting the CPU identifier on which this virtual
      machine should be executed.  Must be a member of all [cpuids] in the
      chained delegation certificates. *)
  val cpuid : Asn.OID.t

  (** [network] is a [SEQUENCE OF UTF8STRING] denoting the bridge devices to
      hook this virtual machine up to.  Each name must be in the chained
      delegation certificates. *)
  val network : Asn.OID.t

  (** [block_device] is a [UTF8STRING] with the name of the block device.  It
      must exist. *)
  val block_device : Asn.OID.t

  (** [vmimage] is a [CHOICE] between [ [0] OCTET_STRING] for an UKVM amd64
      image and [ [1] OCTET_STRING] for an UKVM arm64 image. *)
  val vmimage : Asn.OID.t

  (** [argv] is a [SEQUENCE OF UTF8STRING] denoting the boot parameters passed
      to the virtual machine image. *)
  val argv : Asn.OID.t

  (** {2 OID used in administrative certificates} *)

  (** [permissions] is a [BIT_STRING] denoting the permissions this certificate
      has: 0 for All, 1 for Info, 2 for Image, 3 for Block, 4 for Statistics, 5
      for Console, 6 for Log. *)
  val permissions : Asn.OID.t


  (** [crl] is a [OCTET_STRING] denoting the revocation list of the intermediate
      CA. *)
  val crl : Asn.OID.t
end

(** {1 Encoding and decoding functions} *)

(** The type of versions of the ASN.1 grammar defined above. *)
type version = [ `AV0 ]

(** [version_eq a b] is true if [a] and [b] are equal. *)
val version_eq : version -> version -> bool

(** [pp_version ppf version] pretty prints [version] onto [ppf]. *)
val pp_version : version Fmt.t

(** [version_to_cstruct ver] is the DER encoded version. *)
val version_to_cstruct : version -> Cstruct.t

(** [version_of_cstruct buffer] is either a decoded version of the DER
    encoding [buffer] or an error. *)
val version_of_cstruct : Cstruct.t -> (version, [> `Msg of string ]) result

(** [permissions_to_cstruct perms] is the DER encoded permission list. *)
val permissions_to_cstruct : Vmm_core.permission list -> Cstruct.t

(** [permissions_of_cstruct buffer] is either a decoded permissions list of
    the DER encoded [buffer] or an error. *)
val permissions_of_cstruct : Cstruct.t -> (Vmm_core.permission list, [> `Msg of string ]) result

(** [bridges_to_cstruct bridges] is the DER encoded bridges. *)
val bridges_to_cstruct : Vmm_core.bridge list -> Cstruct.t

(** [bridges_of_cstruct buffer] is either a decoded bridge list of the DER
    encoded [buffer] or an error. *)
val bridges_of_cstruct : Cstruct.t -> (Vmm_core.bridge list, [> `Msg of string ]) result

(** [image_to_cstruct (typ, img)] is the DER encoded image. *)
val image_to_cstruct : Vmm_core.vmtype * Cstruct.t -> Cstruct.t

(** [image_of_cstruct buffer] is either a decoded image of the DER encoded
    [buffer] or an error. *)
val image_of_cstruct : Cstruct.t -> (Vmm_core.vmtype * Cstruct.t, [> `Msg of string ]) result

(** [int_to_cstruct i] is the DER encoded int. *)
val int_to_cstruct : int -> Cstruct.t

(** [int_of_cstruct buffer] is either a decoded int of the DER encoded [buffer]
    or an error. *)
val int_of_cstruct : Cstruct.t -> (int, [> `Msg of string ]) result

(** [ints_to_cstruct xs] is the DER encoded int sequence. *)
val ints_to_cstruct : int list -> Cstruct.t

(** [ints_of_cstruct buffer] is either a decoded int list of the DER encoded
    [buffer] or an error. *)
val ints_of_cstruct : Cstruct.t -> (int list, [> `Msg of string ]) result

(** [string_to_cstruct s] is the DER encoded string. *)
val string_to_cstruct : string -> Cstruct.t

(** [string_of_cstruct buffer] is either a decoded string of the DER encoded
    [buffer] or an error. *)
val string_of_cstruct : Cstruct.t -> (string, [> `Msg of string ]) result

(** [strings_to_cstruct xs] is the DER encoded string sequence. *)
val strings_to_cstruct : string list -> Cstruct.t

(** [strings_of_cstruct buffer] is either a decoded string list of the DER
    encoded [buffer] or an error. *)
val strings_of_cstruct : Cstruct.t -> (string list, [> `Msg of string ]) result

(** {1 Decoding functions} *)

(** [contains_vm cert] is [true] if the certificate contains a virtual machine image. *)
val contains_vm : X509.t -> bool

(** [contains_crl cert] is [true] if the certificate contains a revocation list. *)
val contains_crl : X509.t -> bool

(** [vm_of_cert id cert] is either the decoded virtual machine configuration, or an error. *)
val vm_of_cert : Vmm_core.id -> X509.t -> (Vmm_core.vm_config, [> `Msg of string ]) result

(** [crl_of_cert id cert] is either the decoded revocation list, or an error. *)
val crl_of_cert : X509.t -> (X509.CRL.c, [> `Msg of string ]) result

(** [delegation_of_cert version cert] is either the decoded delegation, or an error. *)
val delegation_of_cert : version -> X509.t -> (Vmm_core.delegation, [> `Msg of string ]) result

(** [permissions_of_cert version cert] is either the decoded permission list, or an error. *)
val permissions_of_cert : version -> X509.t -> (Vmm_core.permission list, [> `Msg of string ]) result
