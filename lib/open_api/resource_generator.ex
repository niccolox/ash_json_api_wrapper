defmodule AshJsonApiWrapper.OpenApi.ResourceGenerator do
  @moduledoc "Generates resources from an open api specification"

  # sobelow_skip ["DOS.StringToAtom"]
  def generate(json, domain, main_config) do
    main_config[:resources]
    |> Enum.map(fn {resource, config} ->

      endpoints =
        json
       |> operations(config)
        |> Enum.map_join("\n\n", fn {path, _method, operation} ->
          entity_path =
            if config[:entity_path] do
              "entity_path \"#{config[:entity_path]}\""
            end

          """
          endpoint :#{operation_id(operation)} do
            path "#{path}"
            #{entity_path}
          end
          """
        end)

      ash_slug =
        case{config[:ash_slug]} do
          {:true} -> "AshSlug"
          _ -> ""
        end

      ash_json =
        case{config[:ash_json]} do
          {:true} -> "AshJsonApi.Resource"
          _ -> ""
        end

      ash_graphql =
        case{config[:ash_graphql]} do
          {:true} -> "AshGraphql.Resource"
          _ -> ""
        end

      ash_admin =
        case{config[:ash_admin]} do
          {:true} -> "AshAdmin.Resource"
          _ -> ""
        end

      ash_state_machine =
        case{config[:ash_state_machine]} do
          {:true} -> "AshStateMachine"
          _ -> ""
        end

      actions =
        json
       |> operations(config)
        |> Enum.map_join("\n\n", fn
          {_path, "get", config} ->
            """
            read :#{operation_id(config)}
            """

          {_path, "post", config} ->
            """
            create :#{operation_id(config)}
            """
        end)

      fields =
        config[:fields]
        |> Enum.map_join("\n\n", fn {name, field_config} ->
          filter_handler =
            if field_config[:filter_handler] do
              "filter_handler #{inspect(field_config[:filter_handler])}"
            end

          """
          field #{inspect(name)} do
            #{filter_handler}
          end
          """
        end)
        |> case do
          "" ->
            ""

          other ->
            """
            fields do
              #{other}
            end
            """
        end

      {:ok, [object]} =
        json
        |> ExJSONPath.eval(config[:object_type])

      attributes =
        object
        |> Map.get("properties")
        |> Enum.map(fn {name, config} ->
          {Macro.underscore(name), config}
        end)
        |> Enum.sort_by(fn {name, _} ->
          name not in List.wrap(config[:primary_key])
        end)
        |> Enum.map_join("\n\n", fn {name, property} ->
          type =
            case property do
              %{"enum" => _values} ->
                ":atom"

              %{"description" => _description} ->
                ":string"

              %{"format" => "date-time"} ->
                ":utc_datetime"

              %{"type" => "string"} ->
                ":string"

              %{"type" => "object"} ->
                ":map"

              %{"type" => "array"} ->
                ":map"

              %{"type" => "integer"} ->
                ":integer"

              %{"type" => "boolean"} ->
                ":boolean"

              other ->
                raise "Unsupported property: #{inspect(other)}"
            end

          constraints =
            case property do
              %{"enum" => values} ->
                "one_of: #{inspect(Enum.map(values, &String.to_atom/1))}"

              %{"maxLength" => max, "minLength" => min, "type" => "string"} ->
                "min_length: #{min}, max_length: #{max}"

              %{"maxLength" => max, "type" => "string"} ->
                "max_length: #{max}"

              %{"minLength" => min, "type" => "string"} ->
                "min_length: #{min}"

              _ ->
                nil
            end

          primary_key? = name in List.wrap(config[:primary_key])

          if constraints || primary_key? do
            constraints =
              if constraints do
                "constraints #{constraints}"
              end

            primary_key =
              if primary_key? do
                """
                primary_key? true
                allow_nil? false
                """
              end

            """
            attribute :#{name}, #{type} do
              #{primary_key}
              #{constraints}
            end
            """
          else
            """
            attribute :#{name}, #{type}
            """
          end
        end)

      tesla =
        if main_config[:tesla] do
          "tesla #{main_config[:tesla]}"
        end

      endpoint =
        if main_config[:endpoint] do
          "base \"#{main_config[:endpoint]}\""
        end

      code =

        case {config[:path]} do

          # no endpoint
          {"__schema__"} ->
            """
            defmodule #{resource} do
              use Ash.Resource,
              domain: #{inspect(domain)},

              extensions: [
                  AshAdmin.Resource,
                  AshJsonApi.Resource,
                  AshGraphql.Resource,
                  AshSlug
              ]

                resource do
                  require_primary_key? false
                end


              actions do
                #{actions}
              end

              attributes do
                #{attributes}
              end
            end
            """
            |> Code.format_string!()
            |> IO.iodata_to_binary()

            # everything else
            _ ->
              """
              defmodule #{resource} do
                use Ash.Resource,
                domain: #{domain},
                extensions: [
                  AshAdmin.Resource,
                  AshJsonApi.Resource,
                  AshGraphql.Resource,
                  AshSlug
                ]


                #{inspect(ash_state_machine)}
                #{inspect(ash_slug)}
                #{inspect(ash_json)}
                #{inspect(ash_graphql)}
                #{inspect(ash_admin)}

                resource do
                  require_primary_key? false
                end

                json_api_wrapper do
                  #{tesla}

                  endpoints do
                    #{endpoint}
                    #{endpoints}
                  end

                  #{fields}
                end

                actions do

                  #{actions}

                end

                attributes do
                  #{attributes}
                end
              end
              """
              |> Code.format_string!()
              |> IO.iodata_to_binary()

        end

        # """
        # defmodule #{resource} do
        #   use Ash.Resource, domain: #{inspect(domain)}, data_layer: AshJsonApiWrapper.DataLayer

        #   json_api_wrapper do
        #     #{tesla}

        #     if #{endpoints} = ""
        #     endpoints do
        #       #{endpoint}
        #       #{endpoints}
        #     end

        #     #{fields}
        #   end

        #   actions do
        #     #{actions}
        #   end

        #   attributes do
        #     #{attributes}
        #   end
        # end
        # """
        # |> Code.format_string!()
        # |> IO.iodata_to_binary()

      {resource, code}
    end)
  end

  def create_list(ash_slug, ash_json, ash_graphql, ash_admin) do
    list = for var <- [ash_slug, ash_json, ash_graphql, ash_admin], var != nil, do: var
    Enum.join(list, ", ")
  end

  defp operation_id(%{"operationId" => operationId}) do
    operationId
    |> Macro.underscore()
  end

  defp operations(json, config) do
    json["paths"]
    |> Enum.filter(fn {path, _value} ->
      String.starts_with?(path, config[:path])
    end)
    |> Enum.flat_map(fn {path, methods} ->
      Enum.map(methods, fn {method, config} ->
        {path, method, config}
      end)
    end)
    |> Enum.filter(fn {_path, method, _config} ->
      method in ["get", "post"]
    end)
  end
end
