defmodule Claudio.A2A.AgentCard do
  @moduledoc """
  A2A Agent Card — describes an agent's identity, capabilities, and skills.

  Discoverable at `{base_url}/.well-known/agent-card.json`.

  ## Parsing a discovered agent card

      {:ok, card} = Claudio.A2A.Client.discover("https://agent.example.com")
      card.name       # "My Agent"
      card.skills     # [%Skill{id: "search", ...}]

  ## Building an agent card

      AgentCard.new("My Agent", "Helps with tasks")
      |> AgentCard.set_version("1.0.0")
      |> AgentCard.set_provider("https://example.com", "My Org")
      |> AgentCard.add_skill("search", "Search the web", tags: ["search", "web"])
      |> AgentCard.add_interface("https://agent.example.com/a2a", "jsonrpc+http", "0.3")
      |> AgentCard.set_capabilities(streaming: true, push_notifications: false)
  """

  defmodule Skill do
    @moduledoc "An agent skill — describes a specific capability."
    import Claudio.A2A.Util, only: [maybe_put: 3]

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            description: String.t(),
            tags: [String.t()],
            examples: [String.t()] | nil,
            input_modes: [String.t()] | nil,
            output_modes: [String.t()] | nil
          }

    defstruct [
      :id,
      :name,
      :description,
      tags: [],
      examples: nil,
      input_modes: nil,
      output_modes: nil
    ]

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        id: map["id"],
        name: map["name"],
        description: map["description"],
        tags: map["tags"] || [],
        examples: map["examples"],
        input_modes: map["inputModes"] || map["input_modes"],
        output_modes: map["outputModes"] || map["output_modes"]
      }
    end

    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = skill) do
      map = %{
        "id" => skill.id,
        "name" => skill.name,
        "description" => skill.description,
        "tags" => skill.tags
      }

      map
      |> maybe_put("examples", skill.examples)
      |> maybe_put("inputModes", skill.input_modes)
      |> maybe_put("outputModes", skill.output_modes)
    end
  end

  defmodule Provider do
    @moduledoc "Agent provider information."
    @type t :: %__MODULE__{url: String.t(), organization: String.t()}
    defstruct [:url, :organization]

    def from_map(map) when is_map(map) do
      %__MODULE__{url: map["url"], organization: map["organization"]}
    end

    def to_map(%__MODULE__{} = p), do: %{"url" => p.url, "organization" => p.organization}
  end

  defmodule Capabilities do
    @moduledoc "Agent capability flags."
    import Claudio.A2A.Util, only: [maybe_put: 3]

    @type t :: %__MODULE__{
            streaming: boolean() | nil,
            push_notifications: boolean() | nil,
            extended_agent_card: boolean() | nil
          }

    defstruct [:streaming, :push_notifications, :extended_agent_card]

    def from_map(map) when is_map(map) do
      %__MODULE__{
        streaming: map["streaming"],
        push_notifications: Map.get(map, "pushNotifications", map["push_notifications"]),
        extended_agent_card: Map.get(map, "extendedAgentCard", map["extended_agent_card"])
      }
    end

    def to_map(%__MODULE__{} = c) do
      %{}
      |> maybe_put("streaming", c.streaming)
      |> maybe_put("pushNotifications", c.push_notifications)
      |> maybe_put("extendedAgentCard", c.extended_agent_card)
    end
  end

  defmodule Interface do
    @moduledoc "Agent interface endpoint."
    import Claudio.A2A.Util, only: [maybe_put: 3]

    @type t :: %__MODULE__{
            url: String.t(),
            protocol_binding: String.t(),
            protocol_version: String.t(),
            tenant: String.t() | nil
          }

    defstruct [:url, :protocol_binding, :protocol_version, :tenant]

    def from_map(map) when is_map(map) do
      %__MODULE__{
        url: map["url"],
        protocol_binding: map["protocolBinding"] || map["protocol_binding"],
        protocol_version: map["protocolVersion"] || map["protocol_version"],
        tenant: map["tenant"]
      }
    end

    def to_map(%__MODULE__{} = i) do
      %{
        "url" => i.url,
        "protocolBinding" => i.protocol_binding,
        "protocolVersion" => i.protocol_version
      }
      |> maybe_put("tenant", i.tenant)
    end
  end

  import Claudio.A2A.Util, only: [maybe_put: 3]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          version: String.t() | nil,
          provider: Provider.t() | nil,
          capabilities: Capabilities.t() | nil,
          default_input_modes: [String.t()],
          default_output_modes: [String.t()],
          skills: [Skill.t()],
          supported_interfaces: [Interface.t()],
          security_schemes: map() | nil,
          security_requirements: list() | nil,
          documentation_url: String.t() | nil,
          icon_url: String.t() | nil,
          signatures: list() | nil
        }

  defstruct [
    :name,
    :description,
    :version,
    :provider,
    :capabilities,
    :security_schemes,
    :security_requirements,
    :documentation_url,
    :icon_url,
    :signatures,
    default_input_modes: [],
    default_output_modes: [],
    skills: [],
    supported_interfaces: []
  ]

  # Builder functions

  @doc "Create a new agent card."
  @spec new(String.t(), String.t()) :: t()
  def new(name, description) when is_binary(name) and is_binary(description) do
    %__MODULE__{name: name, description: description}
  end

  @spec set_version(t(), String.t()) :: t()
  def set_version(%__MODULE__{} = card, version) when is_binary(version) do
    %{card | version: version}
  end

  @spec set_provider(t(), String.t(), String.t()) :: t()
  def set_provider(%__MODULE__{} = card, url, organization) do
    %{card | provider: %Provider{url: url, organization: organization}}
  end

  @spec add_skill(t(), String.t(), String.t(), keyword()) :: t()
  def add_skill(%__MODULE__{skills: skills} = card, id, description, opts \\ []) do
    skill = %Skill{
      id: id,
      name: Keyword.get(opts, :name, id),
      description: description,
      tags: Keyword.get(opts, :tags, [])
    }

    %{card | skills: skills ++ [skill]}
  end

  @spec add_interface(t(), String.t(), String.t(), String.t()) :: t()
  def add_interface(
        %__MODULE__{supported_interfaces: interfaces} = card,
        url,
        protocol_binding,
        protocol_version
      ) do
    iface = %Interface{
      url: url,
      protocol_binding: protocol_binding,
      protocol_version: protocol_version
    }

    %{card | supported_interfaces: interfaces ++ [iface]}
  end

  @spec set_capabilities(t(), keyword()) :: t()
  def set_capabilities(%__MODULE__{} = card, opts) when is_list(opts) do
    caps = %Capabilities{
      streaming: Keyword.get(opts, :streaming),
      push_notifications: Keyword.get(opts, :push_notifications),
      extended_agent_card: Keyword.get(opts, :extended_agent_card)
    }

    %{card | capabilities: caps}
  end

  # Serialization

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      name: map["name"],
      description: map["description"],
      version: map["version"],
      provider: if(map["provider"], do: Provider.from_map(map["provider"])),
      capabilities: if(map["capabilities"], do: Capabilities.from_map(map["capabilities"])),
      default_input_modes: map["defaultInputModes"] || map["default_input_modes"] || [],
      default_output_modes: map["defaultOutputModes"] || map["default_output_modes"] || [],
      skills: parse_skills(map["skills"]),
      supported_interfaces:
        parse_interfaces(map["supportedInterfaces"] || map["supported_interfaces"]),
      security_schemes: map["securitySchemes"] || map["security_schemes"],
      security_requirements: map["securityRequirements"] || map["security_requirements"],
      documentation_url: map["documentationUrl"] || map["documentation_url"],
      icon_url: map["iconUrl"] || map["icon_url"],
      signatures: map["signatures"]
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = card) do
    %{
      "name" => card.name,
      "description" => card.description,
      "defaultInputModes" => card.default_input_modes,
      "defaultOutputModes" => card.default_output_modes,
      "skills" => Enum.map(card.skills, &Skill.to_map/1),
      "supportedInterfaces" => Enum.map(card.supported_interfaces, &Interface.to_map/1)
    }
    |> maybe_put("version", card.version)
    |> maybe_put("provider", if(card.provider, do: Provider.to_map(card.provider)))
    |> maybe_put(
      "capabilities",
      if(card.capabilities, do: Capabilities.to_map(card.capabilities))
    )
    |> maybe_put("securitySchemes", card.security_schemes)
    |> maybe_put("securityRequirements", card.security_requirements)
    |> maybe_put("documentationUrl", card.documentation_url)
    |> maybe_put("iconUrl", card.icon_url)
    |> maybe_put("signatures", card.signatures)
  end

  defp parse_skills(nil), do: []
  defp parse_skills(list) when is_list(list), do: Enum.map(list, &Skill.from_map/1)

  defp parse_interfaces(nil), do: []
  defp parse_interfaces(list) when is_list(list), do: Enum.map(list, &Interface.from_map/1)
end
