Require Import Verdi.Verdi.

Require Import Cheerios.Cheerios.

Set Implicit Arguments.

Section Log.
  Context {orig_base_params : BaseParams}.
  Context {orig_multi_params : MultiParams orig_base_params}.
  Context {orig_failure_params : FailureParams orig_multi_params}.
  Context {data_serializer : Serializer data}.
  Context {l_name_serializer : Serializer name}.
  Context {msg_serializer : Serializer msg}.
  Context {input_serializer : Serializer input}.

  Definition log_net_handlers dst src m st : IOStreamWriter.t *
                                             list output *
                                             data *
                                             list (name * msg)  :=
    let '(out, data, ps) := net_handlers dst src m st in
    (serialize (inr (src , m)), out, data, ps).

  Definition log_input_handlers h inp st : IOStreamWriter.t *
                                           list output *
                                           data *
                                           list (name * msg) :=
    let '(out, data, ps) := input_handlers h inp st in
    (serialize (inl inp), out, data, ps).

  Fixpoint apply_log h (d : data) (entries : list (input + (name * msg))) : data :=
    match entries with
    | [] => d
    | e :: entries =>
      apply_log h
                (match e with
                 | inl inp => match log_input_handlers h inp d with
                              | (_, _, d, _) => d
                              end
                 | inr (src, m) => match log_net_handlers h src m d with
                                   | (_, _, d, _) => d
                                   end
                 end) 
                entries
    end.
  
  Instance log_base_params : BaseParams :=
    {
      data := data ;
      input := input ;
      output := output
    }.

  Definition init_log h :=
    (serialize 0, serialize (init_handlers h), list_serialize_rec (input + name * msg) _ []).

  Instance log_multi_params : LogMultiParams log_base_params :=
    {
      l_name := name;
      l_name_eq_dec := name_eq_dec;
      l_msg := msg;
      l_msg_eq_dec := msg_eq_dec;
      l_nodes := nodes;
      l_all_names_nodes := all_names_nodes;
      l_no_dup_nodes := no_dup_nodes;
      l_init_handlers := init_handlers;
      l_init_log := init_log;
      l_net_handlers := log_net_handlers;
      l_input_handlers := log_input_handlers
    }.

  Definition wire_to_log lw : option (nat * data * list (input + (name * msg))) :=
    match lw with
    | (nw, dw, ew) =>
      match deserialize_top deserialize nw with
      | Some n =>
        match deserialize_top deserialize dw with
        | Some d =>
          match deserialize_top (list_deserialize_rec _ _ n) ew with
          | Some entries => Some (n, d, entries)
          | None => None
          end
        | None => None
        end
      | None => None
      end
    end.

  Definition deserialize_apply_log h lw :=
    match wire_to_log lw with
    | Some (n, d, entries) => apply_log h d entries
    | None => l_init_handlers h
    end.

  Instance log_failure_params : LogFailureParams log_multi_params :=
    {
      l_reboot :=
        fun h lw =>
          @reboot _ _ orig_failure_params
                  (deserialize_apply_log h lw)
    }.
End Log.

Hint Extern 5 (@BaseParams) => apply log_base_params : typeclass_instances.
Hint Extern 5 (@DiskMultiParams _) => apply log_multi_params : typeclass_instances.
Hint Extern 5 (@DiskFailureParams _ _) => apply log_failure_params : typeclass_instances.
