# Runs the OpenTelemetry handler from guides/telemetry.md against stubbed API calls and
# checks the exported spans. CI: `elixir scripts/check_otel_guide.exs`.
Mix.install(
  [
    {:claudio, path: Path.expand("..", __DIR__)},
    {:opentelemetry_api, "~> 1.4"},
    {:opentelemetry, "~> 1.5"},
    {:opentelemetry_telemetry, "~> 1.1"},
    {:plug, "~> 1.16"}
  ],
  # Export each span as it ends (simple processor) and nowhere else until the pid exporter is set.
  config: [opentelemetry: [span_processor: :simple, traces_exporter: :none]]
)

defmodule CheckOtelGuide do
  require Record
  Record.defrecord(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  def next_span! do
    receive do
      {:span, span(name: name, attributes: attributes, events: events)} ->
        {name, :otel_attributes.map(attributes), :otel_events.list(events)}
    after
      2_000 -> raise "no span exported"
    end
  end

  def check!(label, true), do: IO.puts("  ok: #{label}")
  def check!(label, false), do: raise("otel guide check failed: #{label}")
end

guide = File.read!(Path.expand("../guides/telemetry.md", __DIR__))

[_, block] = String.split(guide, "<!-- otel-handler:start -->", parts: 2)
[block, _] = String.split(block, "<!-- otel-handler:end -->", parts: 2)
[_, code, _] = String.split(block, "```", parts: 3)
code = String.replace_prefix(code, "elixir\n", "")
Code.eval_string(code)

:otel_simple_processor.set_exporter(:otel_exporter_pid, self())
# Attach exactly as the guide tells users to.
MyApp.ClaudioOtel.setup()

# 1. Successful non-streaming call.
ok_body = %{
  "id" => "msg_1",
  "type" => "message",
  "role" => "assistant",
  "model" => "m",
  "content" => [%{"type" => "text", "text" => "hi"}],
  "stop_reason" => "end_turn",
  "usage" => %{"input_tokens" => 10, "output_tokens" => 2, "cache_read_input_tokens" => 3}
}

client =
  Claudio.Client.new(%{token: "t"})
  |> Req.merge(plug: fn conn -> Req.Test.json(conn, ok_body) end)

request =
  Claudio.Messages.Request.new("m")
  |> Claudio.Messages.Request.add_message(:user, "hi")
  |> Claudio.Messages.Request.set_max_tokens(8)
  |> Claudio.Messages.Request.set_output_format(%{"type" => "object"})

{:ok, _} = Claudio.Messages.create(client, request)

IO.puts("success span:")
{name, attrs, _events} = CheckOtelGuide.next_span!()
CheckOtelGuide.check!(~s(name is "chat m"; got #{inspect(name)}), name == "chat m")

CheckOtelGuide.check!(
  "finish_reasons is [\"end_turn\"]; got #{inspect(attrs["gen_ai.response.finish_reasons"])}",
  attrs["gen_ai.response.finish_reasons"] == ["end_turn"]
)

CheckOtelGuide.check!(
  "input_tokens includes cached (13); got #{inspect(attrs["gen_ai.usage.input_tokens"])}",
  attrs["gen_ai.usage.input_tokens"] == 13
)

CheckOtelGuide.check!(
  ~s(output.type is "json"; got #{inspect(attrs["gen_ai.output.type"])}),
  attrs["gen_ai.output.type"] == "json"
)

# 2. Erlang-error exception path: a 200 whose `content` is a string makes response parsing raise
# `error:function_clause`, so the create :exception event carries the raw atom as `reason`.
bad_client =
  Claudio.Client.new(%{token: "t"})
  |> Req.merge(plug: fn conn -> Req.Test.json(conn, %{"content" => "x"}) end)

try do
  Claudio.Messages.create(bad_client, %{"model" => "m", "max_tokens" => 8, "messages" => []})
  raise "expected create/2 to raise on a malformed 200"
rescue
  FunctionClauseError -> :ok
end

IO.puts("Erlang-error span:")
{name, attrs, events} = CheckOtelGuide.next_span!()
CheckOtelGuide.check!(~s(name is "chat m"; got #{inspect(name)}), name == "chat m")

CheckOtelGuide.check!(
  ~s(error.type names the exception, not "error"; got #{inspect(attrs["error.type"])}),
  attrs["error.type"] == "FunctionClauseError"
)

CheckOtelGuide.check!(
  "one exception event recorded; got #{length(events)}",
  length(events) == 1
)

IO.puts("otel guide check: ok")
