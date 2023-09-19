defmodule ElvenGard.ECS.Command do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.Query

  TL;DR: Write in Backend (DIRTY or Transaction depending on the context)
  """

  alias ElvenGard.ECS.{Component, Config, Entity, Query}

  ## Transactions

  @spec transaction((() -> result)) :: {:error, result} | {:ok, any()} when result: any()
  def transaction(query) do
    Config.backend().transaction(query)
  end

  @spec abort(any()) :: no_return()
  def abort(reason) do
    Config.backend().abort(reason)
  end

  ## Entities

  @doc """
  Transactional way to spawn an Entity
  """
  @spec spawn_entity(Entity.spec()) :: {:ok, Entity.t()} | {:error, reason}
        when reason: :already_exists | :cant_set_children
  def spawn_entity(specs) when is_map(specs) do
    %{
      components: components,
      children: children
    } = specs

    fn ->
      with {:ok, entity} <- create_entity(specs),
           :ok <- set_children(entity, children),
           :ok <- add_components(entity, components) do
        entity
      else
        {:error, reason} -> abort(reason)
      end
    end
    |> transaction()
  end

  @spec despawn_entity(Entity.t(), (Entity.t(), [Component.t()] -> :delete | :ignore)) ::
          {:ok, {Entity.t(), [Component.t()]}} | {:error, any}
  @doc """
  Transactional way to despawn an Entity
  """
  def despawn_entity(%Entity{} = entity, on_child_delete \\ fn _, _ -> :delete end) do
    fn ->
      # Delete or update each children
      entity
      |> Query.children()
      |> then(&unwrap/1)
      |> Enum.map(&{&1, unwrap(Query.list_components(&1))})
      |> Enum.map(fn {entity, components} = tuple ->
        {tuple, on_child_delete.(entity, components)}
      end)
      |> Enum.each(&maybe_despawn_child(&1, on_child_delete))

      # Delete the parent
      {:ok, components} = Config.backend().delete_components_for(entity)
      :ok = Config.backend().delete_entity(entity)

      # Returns the parent entity and its components
      {entity, components}
    end
    |> transaction()
  end

  @doc """
  TODO: Documentation
  """
  @spec set_parent(Entity.t(), Entity.t() | nil) :: :ok | {:error, :not_found}
  def set_parent(%Entity{} = entity, parent) do
    Config.backend().set_parent(entity, parent)
  end

  @doc """
  TODO: Documentation
  """
  @spec add_component(Entity.t(), Component.spec()) :: Component.t()
  def add_component(%Entity{} = entity, component_spec) do
    Config.backend().add_component(entity, component_spec)
  end

  ## Components

  ## Private helpers

  defp unwrap({:ok, value}), do: value

  defp create_entity(%{id: id, parent: parent}) do
    Config.backend().create_entity(id, parent)
  end

  defp set_children(entity, children) do
    children
    |> Enum.map(&set_parent(&1, entity))
    |> Enum.all?(&match?(:ok, &1))
    |> then(&if &1, do: :ok, else: {:error, :cant_set_children})
  end

  defp add_components(entity, components) do
    Enum.each(components, &add_component(entity, &1))
  end

  defp maybe_despawn_child({_tuple, :ignore}, _on_child_delete), do: :ok

  defp maybe_despawn_child({{entity, _components}, :delete}, on_child_delete) do
    despawn_entity(entity, on_child_delete)
  end

  defp maybe_despawn_child({tuple, value}, _on_child_delete) do
    raise "on_child_delete/2 must returns :ignore or :delete. " <>
            "Got #{inspect(value)} for #{inspect(tuple, limit: :infinity)}"
  end
end
