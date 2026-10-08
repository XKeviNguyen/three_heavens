module OpenRouterCatalogFixture
  PROVIDERS = %w[anthropic openai google meta-llama mistralai deepseek qwen cohere].freeze
  NAMES = [
    "Claude Sonnet", "Claude Haiku", "GPT-4o", "GPT-4o mini", "Gemini 2.5 Flash",
    "Gemini 2.5 Pro", "Llama 3.1 70B", "Llama 3.1 8B", "Mistral Large", "Mistral Small",
    "DeepSeek Chat", "DeepSeek Reasoner", "Qwen 2.5 72B", "Qwen 2.5 7B", "Command R+",
    "Claude Opus", "o3 mini", "Gemini 2.0 Flash Lite", "Llama 3.3 70B", "Mixtral 8x22B",
    "Gemma 2 27B", "Phi-4", "Yi Large", "Solar Pro", "Nova Pro", "Nova Lite",
    "Grok 2", "Command R", "DBRX Instruct", "Jamba 1.5", "Reka Core", "Arctic Instruct",
    "Falcon 2 11B", "Olmo 2", "Granite 3", "Nemotron 4", "Aya 23", "SeaLLM 3", "Vikhr",
    "Sarvam 2"
  ].freeze

  def self.models
    NAMES.each_with_index.map do |name, index|
      provider = PROVIDERS[index % PROVIDERS.size]
      structured = index % 5 != 4
      free = (index % 11).zero?
      {
        "id" => "#{provider}/#{name.downcase.gsub(/[^a-z0-9]+/, '-')}",
        "name" => "#{provider.capitalize}: #{name}",
        "context_length" => [ 32_000, 128_000, 200_000, 1_000_000 ][index % 4],
        "architecture" => { "input_modalities" => [ "text" ], "output_modalities" => [ "text" ] },
        "top_provider" => { "max_completion_tokens" => [ 4_096, 8_192, 16_384 ][index % 3] },
        "pricing" => {
          "prompt" => free ? "0" : "0.000000#{(index % 9) + 1}",
          "completion" => free ? "0" : "0.00000#{(index % 9) + 1}"
        },
        "supported_parameters" => structured ? %w[max_tokens response_format structured_outputs] : %w[max_tokens]
      }
    end
  end

  def self.to_json
    JSON.generate("data" => models)
  end
end
