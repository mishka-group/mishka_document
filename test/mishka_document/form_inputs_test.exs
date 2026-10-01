defmodule MishkaDocument.FormInputsTest do
  @moduledoc """
  Every field a document form lets a person change is one the action it saves with takes.

  A field the form draws as editable but the action does not take is dropped by the save without a
  word: the person sees "saved" and nothing changed. For every resource of the domain that has a form,
  in both modes and for a master and a site admin, the fields that person can change are compared with
  the inputs of the action `MishkaGervaz.Resource.Info.Form.action_for/3` names for them.

  A field can be changed when the person may see it (`MishkaGervaz.Helpers.accessible?/2`), it is drawn
  in that mode (`show_on`) and it is not read-only there. The form is opened with no defaults, which is
  when the most fields can be changed. A virtual field only helps pick another one and is never saved,
  so it is left out.
  """
  use ExUnit.Case, async: true

  alias MishkaGervaz.Resource.Info.Form, as: FormInfo

  test "no document form offers a change its save drops" do
    forms =
      MishkaDocument
      |> Ash.Domain.Info.resources()
      |> Enum.filter(&(FormInfo.fields(&1) != []))

    assert forms != []

    dropped =
      for resource <- forms,
          mode <- [:create, :update],
          master? <- [true, false],
          action =
            Ash.Resource.Info.action(resource, FormInfo.action_for(resource, mode, master?)),
          field <- FormInfo.fields(resource),
          changeable?(field, form_state(mode, master?)),
          field.name not in inputs(action),
          do: {resource, mode, if(master?, do: :master, else: :site_admin), field.name}

    assert dropped == []
  end

  defp form_state(mode, master?),
    do: %{
      mode: mode,
      master_user?: master?,
      defaults: %{},
      field_values: %{},
      current_user: %{id: Ash.UUID.generate(), site_id: if(!master?, do: Ash.UUID.generate())}
    }

  defp changeable?(%{virtual: true}, _state), do: false

  defp changeable?(field, state),
    do:
      MishkaGervaz.Helpers.accessible?(field, state) and field.show_on in [nil, state.mode] and
        not readonly?(field.readonly, state)

  defp readonly?(readonly, state) when is_function(readonly, 1), do: readonly.(state)
  defp readonly?(readonly, _state), do: readonly == true

  defp inputs(action), do: (action.accept || []) ++ Enum.map(action.arguments, & &1.name)
end
