defmodule AshPostgres.Calculation do
  @moduledoc false

  require Ecto.Query

  def add_calculations(query, [], _, _, _select?), do: {:ok, query}

  def add_calculations(query, calculations, resource, source_binding, select?) do
    query = AshPostgres.DataLayer.default_bindings(query, resource)

    {:ok, query} =
      AshPostgres.Join.join_all_relationships(
        query,
        %Ash.Filter{
          resource: resource,
          expression: Enum.map(calculations, &elem(&1, 1))
        },
        left_only?: true
      )

    aggregates =
      calculations
      |> Enum.flat_map(fn {calculation, expression} ->
        expression
        |> Ash.Filter.used_aggregates([])
        |> Enum.map(&Map.put(&1, :context, calculation.context))
      end)
      |> Enum.uniq()

    case AshPostgres.Aggregate.add_aggregates(
           query,
           aggregates,
           query.__ash_bindings__.resource,
           false,
           source_binding
         ) do
      {:ok, query} ->
        if select? do
          query =
            if query.select do
              query
            else
              Ecto.Query.select_merge(query, %{})
            end

          {dynamics, query} =
            Enum.reduce(calculations, {[], query}, fn {calculation, expression}, {list, query} ->
              type =
                AshPostgres.Types.parameterized_type(
                  calculation.type,
                  Map.get(calculation, :constraints, [])
                )

              expression =
                Ash.Actions.Read.add_calc_context_to_filter(
                  expression,
                  calculation.context[:actor],
                  calculation.context[:authorize?],
                  calculation.context[:tenant],
                  calculation.context[:tracer]
                )

              {expr, acc} =
                AshPostgres.Expr.dynamic_expr(
                  query,
                  expression,
                  query.__ash_bindings__,
                  false,
                  type
                )

              expr =
                if type do
                  Ecto.Query.dynamic(type(^expr, ^type))
                else
                  expr
                end

              {[{calculation.load, calculation.name, expr} | list],
               AshPostgres.DataLayer.merge_expr_accumulator(query, acc)}
            end)

          {:ok, add_calculation_selects(query, dynamics)}
        else
          {:ok, query}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp add_calculation_selects(query, dynamics) do
    {in_calculations, in_body} =
      Enum.split_with(dynamics, fn {load, _name, _dynamic} -> is_nil(load) end)

    calcs =
      in_body
      |> Map.new(fn {load, _, dynamic} ->
        {load, dynamic}
      end)

    calcs =
      if Enum.empty?(in_calculations) do
        calcs
      else
        Map.put(
          calcs,
          :calculations,
          Map.new(in_calculations, fn {_, name, dynamic} ->
            {name, dynamic}
          end)
        )
      end

    Ecto.Query.select_merge(query, ^calcs)
  end
end
