Require Import Verdi.Verdi.

Require Import Cheerios.Cheerios.

Import DeserializerNotations.

Set Implicit Arguments.

Class LogParams `(P : MultiParams) :=
  {
    log_data_serializer :> Serializer data ;
    log_name_serializer :> Serializer name ;
    log_msg_serializer :> Serializer msg ;
    log_input_serializer :> Serializer input ;
    log_snapshot_interval : nat
  }.

Section Log.
  Context {orig_base_params : BaseParams}.
  Context {orig_multi_params : MultiParams orig_base_params}.
  Context {orig_failure_params : FailureParams orig_multi_params}.
  Context {log_params : LogParams orig_multi_params}.

  Definition entry : Type := input + (name * msg).

  Inductive log_files :=
  | Count
  | Snapshot
  | Log.

  Definition log_files_eq_dec : forall x y : log_files, {x = y} + {x <> y}.
    decide equality.
  Defined.

  Record log_state :=
    mk_log_state { log_num_entries : nat ;
                   log_data : data }.

  Definition log_net_handlers dst src m st : list (disk_op log_files) *
                                             list output *
                                             log_state *
                                             list (name * msg)  :=
    let '(out, data, ps) := net_handlers dst src m (log_data st) in
    let n := log_num_entries st in
    if S n =? log_snapshot_interval
    then ([Delete Log; Write Snapshot (serialize data); Write Count (serialize 0)],
          out,
          mk_log_state 0 data,
          ps)
    else ([Append Log (serialize (inr (src , m) : entry)); Write Count (serialize (S n))],
          out,
          mk_log_state (S n) data,
          ps).

  Definition log_input_handlers h inp st : list (disk_op log_files) *
                                           list output *
                                           log_state *
                                           list (name * msg) :=
    let '(out, data, ps) := input_handlers h inp (log_data st) in
    let n := log_num_entries st in
    if S n =? log_snapshot_interval
    then ([Delete Log; Write Snapshot (serialize data); Write Count (serialize 0)],
          out,
          mk_log_state 0 data,
          ps)
    else ([Append Log (serialize (inl inp : entry)); Write Count (serialize (S n))],
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
    match deserialize_top deserialize (w Count), deserialize_top deserialize (w Snapshot) with
    | Some n, Some d =>
      match deserialize_top (list_deserialize_rec' _ _ n) (w Log) with
      | Some es => Some (n, d, es)
      | None => None
      end
    | _, _ => None
    end.

  Definition apply_entry h d e :=
    match e with
     | inl inp => let '(_, d', _) := input_handlers h inp d in d'
     | inr (src, m) => let '(_, d', _) := net_handlers h src m d in d'
    end.

  Fixpoint apply_log h (d : @data orig_base_params) (entries : list entry) : @data orig_base_params :=
    match entries with
    | [] => d
    | e :: entries => apply_log h (apply_entry h d e) entries
    end.

  Lemma apply_log_app : forall h d entries e,
      apply_log h d (entries ++ [e]) =
      apply_entry h (apply_log h d entries) e.
  Proof.
    intros.
    generalize dependent d.
    induction entries.
    - reflexivity.
    - intros.
      simpl.
      rewrite IHentries.
      reflexivity.
  Qed.

  Lemma serialize_empty : forall A,
    ByteListReader.unwrap (ByteListReader.ret (@nil A))
                          (IOStreamWriter.unwrap IOStreamWriter.empty) = Some ([], []).
  Proof.
    cheerios_crush.
  Qed.

  Lemma serialize_snoc : forall {A} {sA : Serializer A} (a : A) l,
      IOStreamWriter.unwrap (list_serialize_rec _ _ l) ++
                            IOStreamWriter.unwrap (serialize a) =
      (IOStreamWriter.unwrap (list_serialize_rec _ _ (l ++ [a]))).
  Proof.
    intros.
    induction l;
      simpl;
      cheerios_crush.
    - rewrite app_nil_r.
      reflexivity.
    - rewrite <- IHl.
      reflexivity.
  Qed.

  Lemma serialize_deserialize_snoc : forall entries e0,
      ByteListReader.unwrap
        (list_deserialize_rec entry _ (S (length entries)))
        (IOStreamWriter.unwrap
           (list_serialize_rec entry _ (entries ++ [e0]))) =
      Some (entries ++ [e0], []).
  Proof.
    intros.
    induction entries.
    - simpl.
      cheerios_crush.
    - assert ((a :: entries) ++ [e0] = a :: entries ++ [e0]) by reflexivity.
      rewrite H.
      unfold list_deserialize_rec.
      rewrite sequence_rewrite.
      rewrite ByteListReader.bind_unwrap.
      rewrite ByteListReader.map_unwrap.
      simpl.
      rewrite IOStreamWriter.append_unwrap.
      rewrite serialize_deserialize_id.
      rewrite ByteListReader.bind_unwrap.
      unfold list_deserialize_rec in IHentries.
      rewrite IHentries.
      cheerios_crush.
  Qed.


  Theorem bar : forall entries e s,
      (forall bytes, ByteListReader.unwrap
                       (list_deserialize_rec entry _ (length entries))
                       (IOStreamWriter.unwrap s ++ bytes) = Some (entries, bytes)) ->
      ByteListReader.unwrap
        (list_deserialize_rec entry _ (S (length entries)))
        (IOStreamWriter.unwrap (s +$+ (@serialize entry _ e))) =
      ByteListReader.unwrap
        (entries <- (list_deserialize_rec entry _ (length entries));;
                 e <- deserialize;;
                 ByteListReader.ret (entries ++ [e]))
        (IOStreamWriter.unwrap (s +$+ serialize e)).
  Proof.
    intros until s.
    induction entries using rev_ind.
    - intros.
      repeat rewrite IOStreamWriter.append_unwrap.
      destruct (IOStreamWriter.unwrap s).
      + repeat rewrite H.
        simpl.
        cheerios_crush.
        rewrite <- (app_nil_r (IOStreamWriter.unwrap (serialize e))).
        rewrite serialize_deserialize_id.
        cheerios_crush.
      + specialize H with [].
        simpl in H.
        rewrite ByteListReader.ret_unwrap in H.
        find_inversion.
    - intros.
      admit.
  Admitted.

  Theorem foo : forall entries n s e,
      n = length entries ->
      (forall bytes, ByteListReader.unwrap
                       (list_deserialize_rec entry _ n)
                       (IOStreamWriter.unwrap s ++ bytes) = Some (entries, bytes)) ->
      ByteListReader.unwrap
        (list_deserialize_rec entry _ (S n))
        (IOStreamWriter.unwrap (s +$+ (@serialize entry _ e))) = Some (entries ++ [e], []).
  Proof.
    induction entries using rev_ind.
    - intros.
      repeat rewrite H.
      simpl.
      admit.
    - intros.
      rewrite IOStreamWriter.append_unwrap.
      specialize IHentries with (length entries) s x.
      concludes.
      rewrite H.
      admit.
  Admitted.


  Theorem foo' : forall n s entries e,
      n = length entries ->
      (forall bytes, ByteListReader.unwrap
                       (list_deserialize_rec entry _ n)
                       (IOStreamWriter.unwrap s ++ bytes) = Some (entries, bytes)) ->
      ByteListReader.unwrap
        (list_deserialize_rec entry _ (S n))
        (IOStreamWriter.unwrap (s +$+ (@serialize entry _ e))) = Some (entries ++ [e], []).
  Proof.
    intros.
    find_rewrite. find_rewrite.
    rewrite bar with (entries := entries).
    - rewrite IOStreamWriter.append_unwrap.
      rewrite ByteListReader.bind_unwrap.
      specialize H0 with
          (IOStreamWriter.unwrap
             (@serialize
                entry
                (sum_Serializer (@input orig_base_params)
            (@name orig_base_params orig_multi_params * @msg orig_base_params orig_multi_params)
            (@log_input_serializer orig_base_params orig_multi_params log_params)
            (pair_Serializer (@name orig_base_params orig_multi_params)
               (@msg orig_base_params orig_multi_params)
               (@log_name_serializer orig_base_params orig_multi_params log_params)
               (@log_msg_serializer orig_base_params orig_multi_params log_params)))
                e)).
      rewrite H0.
      cheerios_crush.
      rewrite <- (app_nil_r (IOStreamWriter.unwrap (serialize e))).
      cheerios_crush.
    - assumption.
  Qed.

  Theorem serialize_snoc' : forall e entries dsk n,
      (forall bytes, ByteListReader.unwrap
                       (list_deserialize_rec entry _ n)
                       (IOStreamWriter.unwrap (dsk Log) ++ bytes) = Some(entries, bytes)) ->
      n = length entries ->
      ByteListReader.unwrap
        (list_deserialize_rec entry _ (S n))
        (IOStreamWriter.unwrap
           (apply_ops dsk [Append Log (serialize e); Write Count (serialize (S n))] Log)) = Some (entries ++ [e], []).
  Proof.
    unfold apply_ops, update_disk, update.
    repeat break_if;
      try congruence.
    intros.
    find_rewrite. find_rewrite.
    rewrite foo' with (entries := entries).
    - reflexivity.
    - reflexivity.
    - assumption.
  Qed.

  Definition disk_correct dsk h st  :=
    exists entries snap,
      IOStreamWriter.unwrap (dsk Log) = IOStreamWriter.unwrap (list_serialize_rec entry _ entries) /\
      log_num_entries st = length entries /\
      ByteListReader.unwrap deserialize (IOStreamWriter.unwrap (dsk Count)) =
      Some (length entries, []) /\
      ByteListReader.unwrap deserialize (IOStreamWriter.unwrap (dsk Snapshot)) =
      Some (snap, []) /\
      (apply_log h snap entries = log_data st).

  Lemma log_net_handlers_spec :
    forall dst src m st
           cs out st' l
           dsk dsk',
      disk_correct dsk dst st ->
      log_net_handlers dst src m st = (cs, out, st', l) ->
      apply_ops dsk cs = dsk' ->
      disk_correct dsk' dst st'.
    intros.
    unfold disk_correct in *.
    break_exists.
    intuition.
    unfold log_net_handlers in *.
    break_if; do 2 break_let.
    - exists [], d.
      intuition.
      + match goal with
        | H : _ = dsk' |- _ => rewrite <- H
        end.
        find_inversion.
        reflexivity.
      + find_inversion.
        reflexivity.
      + match goal with
        | H : _ = dsk' |- _ => rewrite <- H
        end.
        find_inversion.
        simpl.
        rewrite serialize_deserialize_id_nil.
        reflexivity.
      + find_inversion.
        simpl.
        rewrite serialize_deserialize_id_nil.
        reflexivity.
      + find_inversion.
        reflexivity.
    - repeat break_and.
      exists (x ++ [inr (src, m)]), x0.
      intuition.
      + match goal with
        | H : _ = dsk' |- _ => rewrite <- H
        end.
        find_inversion.
        simpl.
        cheerios_crush.
        match goal with
        | H : IOStreamWriter.unwrap (dsk Log) = _ |- _ => rewrite H
        end.
        rewrite serialize_snoc.
        reflexivity.
      + find_inversion.
        repeat find_rewrite.
        rewrite app_length.
        rewrite PeanoNat.Nat.add_1_r.
        reflexivity.
      + match goal with
        | H : _ = dsk' |- _ => rewrite <- H
        end.
        find_inversion.
        simpl.
        rewrite serialize_deserialize_id_nil.
        rewrite app_length.
        rewrite PeanoNat.Nat.add_1_r.
        repeat find_rewrite.
        reflexivity.
      + match goal with
        | H : _ = dsk' |- _ => rewrite <- H
        end.
        find_inversion.
        simpl.
        assumption.
      + rewrite apply_log_app.
        match goal with
        | H : apply_log _ _ _ = _ |- _ => rewrite H
        end.
        find_inversion.
        simpl.
        match goal with
        | H : net_handlers _ _ _ _ = _ |- _ => rewrite H
        end.
        reflexivity.
  Qed.

  Lemma log_input_handlers_spec :
    forall dst m st
           cs out st' l
           dsk dsk',
      disk_correct dsk dst st ->
      log_input_handlers dst m st = (cs, out, st', l) ->
      apply_ops dsk cs = dsk' ->
      disk_correct dsk' dst st'.
    intros.
    unfold disk_correct in *.
    break_exists.
    intuition.
    unfold log_input_handlers in *.
    break_if; do 2 break_let.
    - exists [], d.
      intuition.
      + match goal with
        | H : _ = dsk' |- _ => rewrite <- H
        end.
        find_inversion.
        reflexivity.
      + find_inversion.
        reflexivity.
      + match goal with
        | H : _ = dsk' |- _ => rewrite <- H
        end.
        find_inversion.
        simpl.
        rewrite serialize_deserialize_id_nil.
        reflexivity.
      + find_inversion.
        simpl.
        rewrite serialize_deserialize_id_nil.
        reflexivity.
      + find_inversion.
        reflexivity.
    - repeat break_and.
      exists (x ++ [inl m]), x0.
      intuition.
      + match goal with
        | H : _ = dsk' |- _ => rewrite <- H
        end.
        find_inversion.
        simpl.
        cheerios_crush.
        match goal with
        | H : IOStreamWriter.unwrap (dsk Log) = _ |- _ => rewrite H
        end.
        rewrite serialize_snoc.
        reflexivity.
      + find_inversion.
        repeat find_rewrite.
        rewrite app_length.
        rewrite PeanoNat.Nat.add_1_r.
        reflexivity.
      + match goal with
        | H : _ = dsk' |- _ => rewrite <- H
        end.
        find_inversion.
        simpl.
        rewrite serialize_deserialize_id_nil.
        rewrite app_length.
        rewrite PeanoNat.Nat.add_1_r.
        repeat find_rewrite.
        reflexivity.
      + match goal with
        | H : _ = dsk' |- _ => rewrite <- H
        end.
        find_inversion.
        simpl.
        assumption.
      + rewrite apply_log_app.
        match goal with
        | H : apply_log _ _ _ = _ |- _ => rewrite H
        end.
        find_inversion.
        simpl.
        match goal with
        | H : input_handlers _ _ _ = _ |- _ => rewrite H
        end.
        reflexivity.
  Qed.

  Definition do_log_reboot (h : do_name) (w : log_files -> IOStreamWriter.wire) :
    data * do_disk log_files :=
    match wire_to_log w with
    | Some (n, d, es) =>
      let d' := reboot (apply_log h d es) in
      (mk_log_state 0 d',
       fun file => match file with
                  | Count => serialize 0
                  | Snapshot => serialize d'
                  | Log => IOStreamWriter.empty
                  end)
    | None =>
      let d' := reboot (init_handlers h) in
      (mk_log_state 0 d',
       fun file => match file with
                  | Count => serialize 0
                  | Snapshot => serialize d'
                  | Log => IOStreamWriter.empty
                  end)
    end.

  Instance log_failure_params : DiskOpFailureParams log_multi_params :=
    { do_reboot := do_log_reboot }.
End Log.

Hint Extern 5 (@BaseParams) => apply log_base_params : typeclass_instances.
Hint Extern 5 (@DiskOpMultiParams _) => apply log_multi_params : typeclass_instances.
Hint Extern 5 (@DiskOpFailureParams _ _) => apply log_failure_params : typeclass_instances.
