Require Import Verdi.Verdi.
Require Import Cheerios.Cheerios.

Require Import Verdi.Log.

Section LogCorrect.
  Context {orig_base_params : BaseParams}.
  Context {orig_multi_params : MultiParams orig_base_params}.
  Context {orig_failure_params : FailureParams orig_multi_params}.

  Context {data_serializer : Serializer data}.
  Context {l_name_serializer : Serializer name}.
  Context {msg_serializer : Serializer msg}.
  Context {input_serializer : Serializer input}.

  Hypothesis reboot_idem : forall d, reboot (reboot d) = reboot d.

  Lemma g :
    @deserialize_top
            (list entry)
            (list_deserialize_rec entry entry_Serializer 0)
            (serialize_top IOStreamWriter.empty) = Some [].
  Proof.
    apply serialize_deserialize_top_id' with (bytes := []).
    unfold list_deserialize_rec.
    cheerios_crush.
  Qed.

  Lemma disk_follows_local_state : forall net failed tr h,
      @step_failure_log_star _ _ log_failure_params step_failure_log_init (failed, net) tr ->
      (@deserialize_apply_log _
                              orig_multi_params
                              _ _ _ _ _
                              h
                              (log_to_wire (nwlLog net h))) =
      (nwlState net h).
  Proof.
    intros.
    remember step_failure_log_init as x.
    change net with (snd (failed, net)).
    induction H using refl_trans_1n_trace_n1_ind.
    - intros.
      find_rewrite.
      simpl.
      unfold deserialize_apply_log.
      repeat break_match.
      + unfold wire_to_log in *.
        repeat break_match; try congruence.
        symmetry in Heqo. find_inversion.
        rewrite serialize_deserialize_top_id in Heqo0.
        rewrite serialize_deserialize_top_id in Heqo1.
        repeat find_inversion.
        rewrite g in *.
        find_inversion.
        reflexivity.
      + reflexivity.
    - concludes.
      destruct H0.
      + destruct net'.
        simpl in *.
        inversion H5.
        break_if.
        * unfold update_log in *.
          unfold log_net_handlers in *.
          repeat break_match.
          -- repeat tuple_inversion.
             match goal with
             | H : _ = Some log |- _ => inversion H
             end.
             unfold deserialize_apply_log.
             repeat break_match.
             ++ admit.
             ++ unfold log_to_wire, wire_to_log in *.
                repeat break_match; try congruence; admit.
          -- inversion H4.
             unfold deserialize_apply_log.
             repeat break_match;
               admit.
          -- inversion H4.
        * assumption.
      + destruct net'.
        simpl in *.
        inversion H5.
        break_if.
        * unfold deserialize_apply_log.
          repeat break_match.
          --
             admit.
          -- admit.
        * assumption.
      + destruct net0 eqn:Hnet0.
        simpl in *.
        assert (Net.nwlLog net' = nwlLog). match goal with
                                           | H : net' = _ |- _ => now rewrite H
                                           end.
        assert (Net.nwlState net' = nwlState). match goal with
                                               | H : net' = _ |- _ => now rewrite H
                                               end.
        * now repeat find_rewrite.
      + destruct net0 eqn:Hnet0.
        simpl in *.
        assert (Net.nwlLog net' = nwlLog). match goal with
                                           | H : net' = _ |- _ => now rewrite H
                                           end.
        assert (Net.nwlState net' = nwlState). match goal with
                                               | H : net' = _ |- _ => now rewrite H
                                               end.
        * now repeat find_rewrite.
      + assumption.
      + simpl in H3. simpl.
        destruct net'.
        inversion H4.
        simpl in *.
         break_if.
        * rewrite <- H3.
          rewrite e in *.
          rewrite IHrefl_trans_1n_trace1.
          symmetry.
          apply reboot_idem.
         * assumption.
  Admitted.

  Definition orig_packet := @packet _ orig_multi_params.
  Definition orig_network := @network _ orig_multi_params.

  Definition log_packet := @l_packet _ log_multi_params.
  Definition log_network := @l_network _ log_multi_params.


  Definition revertPacket (p : log_packet) : orig_packet :=
    @mkPacket _ orig_multi_params (l_pSrc p) (l_pDst p) (l_pBody p).

  Definition revertLogNetwork (net: log_network) : orig_network :=
    mkNetwork (map revertPacket (nwlPackets net)) (nwlState net).

  Theorem disk_step_failure_step :
    forall net net' failed failed' tr tr',
      @step_failure_log_star _ _ log_failure_params step_failure_log_init (failed, net) tr ->
      @step_failure_log _ _ log_failure_params (failed, net) (failed', net') tr' ->
      step_failure (failed, revertLogNetwork net)
                   (failed', revertLogNetwork net')
                   tr'.
  Proof.
    intros.
    assert (revert_packets : forall net, nwPackets (revertLogNetwork net) =
                        map revertPacket (nwlPackets net)) by reflexivity.
    assert (revert_send : forall l h,
               map revertPacket (l_send_packets h l) = send_packets h l).
      { induction l.
        * reflexivity.
        * intros.
          simpl.
          now rewrite IHl.
      }
    invcs H0.
    - unfold revertLogNetwork in *.
      simpl.
      repeat find_rewrite.
      rewrite map_app.
      simpl in *. unfold log_net_handlers in *.
      repeat break_let. simpl.
      assert (l_pDst p = pDst (revertPacket p)) by reflexivity.
      repeat find_rewrite.
      find_inversion.
      repeat rewrite map_app.

      apply StepFailure_deliver with (xs0 := map revertPacket xs)
                                     (ys0 := map revertPacket ys)
                                     (d0 := d)
                                     (l0 := l).
      + reflexivity.
      + assumption.
      + assumption.
      + simpl.
        now rewrite revert_send.
    - unfold revertLogNetwork in *. simpl. repeat find_rewrite.
      simpl in *. unfold log_input_handlers in *.
      repeat break_let. find_inversion.
      rewrite map_app.
      rewrite revert_send.
      match goal with
      | H : input_handlers _ _ _ = (_, ?d, ?l) |- _ =>
        apply StepFailure_input with (d0 := d) (l0 := l); auto
      end.
    - unfold revertLogNetwork.
      simpl.
      find_rewrite.
      repeat rewrite map_app.
      simpl.
      match goal with
      | H : _ = ?xs ++ ?p :: ?ys |- _ =>
        apply StepFailure_drop with (p0 := revertPacket p)
                                    (xs0 :=  map revertPacket xs)
                                    (ys0 := map revertPacket ys)
      end; reflexivity.
    - unfold revertLogNetwork.
      match goal with H : nwlPackets net = _ |- _ => rewrite H end.
      rewrite map_app. simpl.
      match goal with
      | H : _ = ?xs ++ ?p :: ?ys |- _ =>
        apply StepFailure_dup with (p0 := revertPacket p)
                                   (xs0 :=  map revertPacket xs)
                                   (ys0 := map revertPacket ys)
      end.
      + reflexivity.
      + now rewrite map_app.
    - apply (@StepFailure_fail _ _ orig_failure_params).
    - match goal with
        H : In ?h _ |- _ => apply StepFailure_reboot with (h0 := h)
      end.
      + assumption.
      + reflexivity.
      + unfold revertLogNetwork. simpl.
        rewrite (disk_follows_local_state _ failed tr);
          auto.
  Qed.
End LogCorrect.
