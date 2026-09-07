module TranslationGuidance
  class Policy
    ORDERS = {
      "reference_examples" => [ "Reference examples", "Experiment instruction", "Glossary", "Methodology" ],
      "glossary" => [ "Glossary", "Experiment instruction", "Reference examples", "Methodology" ],
      "experiment_instruction" => [ "Experiment instruction", "Glossary", "Reference examples", "Methodology" ]
    }.freeze

    LABELS = {
      "reference_examples" => "Reference examples",
      "glossary" => "Glossary terminology",
      "experiment_instruction" => "This translation instruction"
    }.freeze

    def self.precedence_statement(value)
      order = ORDERS.fetch(value)
      "Effective guidance order: Product/system rules > #{order.join(' > ')}."
    end

    def self.label(value)
      LABELS.fetch(value)
    end
  end
end
