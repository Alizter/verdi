Require Import Verdi.Verdi.

Require Import Cheerios.Cheerios.

Import DeserializerNotations.

Set Implicit Arguments.

Section Log.
  Context {orig_base_params : BaseParams}.
  Context {orig_multi_params : MultiParams orig_base_params}.
  Context {orig_failure_params : FailureParams orig_multi_params}.
  Context {data_serializer : Serializer data}.
  Context {l_name_serializer : Serializer name}.
  Context {msg_serializer : Serializer msg}.
  Context {input_serializer : Serializer input}.
  Context {snapshot_interval : nat}.

  Definition entry : Type := input + (name * msg).

  Inductive log_files :=
  | Count
  | Snapshot
  | Log.

  Lemma log_files_eq_dec : forall x y : log_files, {x = y} + {x <> y}.
  Proof.
    decide equality.
  Qed.

  Record log_state := mk_log_state { log_num_entries : nat ;
                                     log_data : data}.

  Definition log_state_serialize d :=
    IOStreamWriter.append (fun _ => serialize (log_num_entries d))
                          (fun _ => serialize (log_data d)).

  Definition log_state_deserialize :=
    n <- deserialize;;
      d <- deserialize;;
      ByteListReader.ret (mk_log_state n d).

  Lemma log_state_serialize_deserialize_id:
    serialize_deserialize_id_spec log_state_serialize log_state_deserialize.
  Proof.
    intros.
    unfold log_state_serialize, log_state_deserialize.
    destruct a.
    cheerios_crush.
  Qed.

  Instance log_state_Serializer : Serializer log_state.
  Proof.
    exact {| serialize := log_state_serialize ;
             deserialize := log_state_deserialize ;
             serialize_deserialize_id := log_state_serialize_deserialize_id
          |}.
  Qed.

  Definition log_net_handlers dst src m st : list (disk_op log_files) *
                                             list output *
                                             log_state *
                                             list (name * msg)  :=
    let '(out, data, ps) := net_handlers dst src m (log_data st) in
    let n := log_num_entries st in
    if S n =? snapshot_interval
    then ([Delete Log; Write Snapshot (serialize data); Write Count (serialize 0)],
          out,
          mk_log_state 0 data,
          ps)
    else ([Append Log (serialize (inr (src , m))); Write Count (serialize (S n))],
          out,
          mk_log_state (S n) data,
          ps).

  Definition log_input_handlers h inp st : list (disk_op log_files) *
                                           list output *
                                           log_state *
                                           list (name * msg) :=
    let '(out, data, ps) := input_handlers h inp (log_data st) in
    let n := log_num_entries st in
    if S n =? snapshot_interval
    then ([Delete Log; Write Snapshot (serialize data); Write Count (serialize 0)],
          out,
          mk_log_state 0 data,
          ps)
    else ([Append Log (serialize (inl inp)); Write Count (serialize (S n))],
          out,
          mk_log_state (S n) data,
          ps).

  Instance log_base_params : BaseParams :=
    {
      data := log_state ;
      input := input ;
      output := output
    }.

  Definition log_init_handlers h :=
    mk_log_state 0 (init_handlers h).

  Definition init_disk (h : name) : do_disk log_files :=
    fun file =>
      match file with
      | Count => serialize 0
      | Snapshot => serialize (init_handlers h)
      | Log => IOStreamWriter.empty
      end.

  Instance log_multi_params : DiskOpMultiParams log_base_params :=
    {
      do_name := name;
      file_name := log_files;
      do_name_eq_dec := name_eq_dec;
      do_msg := msg;
      do_msg_eq_dec := msg_eq_dec;
      file_name_eq_dec := log_files_eq_dec;
      do_nodes := nodes;
      do_all_names_nodes := all_names_nodes;
      do_no_dup_nodes := no_dup_nodes;
      do_init_handlers := log_init_handlers;
      do_init_disk := init_disk;
      do_net_handlers := log_net_handlers;
      do_input_handlers := log_input_handlers
    }.

  Definition wire_to_log (w : file_name -> IOStreamWriter.wire) : option (nat * @data orig_base_params * list entry) :=
    match deserialize_top deserialize (w Count) with
    | Some n =>
      match deserialize_top deserialize (w Snapshot) with
      | Some d =>
        match deserialize_top (list_deserialize_rec _ _ n) (w Log) with
        | Some es => Some (n, d, es)
        | None => None
        end
      | None => None
      end
    | None => None
    end.

  Fixpoint apply_log h (d : data) (entries : list entry) : data :=
    match entries with
    | [] => d
    | e :: entries =>
      apply_log h
                (match e with
                 | inl inp => match log_input_handlers h inp d with
                              | (_, _, d, _) => d
                                   end
                 | inr (src, m) =>  match log_net_handlers h src m d with
                                       | (_, _, d, _) => d
                                    end
                 end)
                entries
    end.

  Definition do_reboot (h : do_name) (w : log_files -> IOStreamWriter.wire) :
    (data * do_disk log_files) :=
    match wire_to_log w with
    | Some (n, d, es) => (apply_log h (mk_log_state n d) es,
                          fun file => match file with
                                      | Count => serialize 0
                                      | Snapshot => serialize d
                                      | Log => IOStreamWriter.empty
                                         end)
    | None => (mk_log_state 0 (init_handlers h), fun _ => IOStreamWriter.empty)
    end.

  Instance log_failure_params : DiskOpFailureParams log_multi_params :=
    { do_reboot := do_reboot }.
End Log.

Hint Extern 5 (@BaseParams) => apply log_base_params : typeclass_instances.
Hint Extern 5 (@DiskMultiParams _) => apply log_multi_params : typeclass_instances.
Hint Extern 5 (@DiskFailureParams _ _) => apply log_failure_params : typeclass_instances.
