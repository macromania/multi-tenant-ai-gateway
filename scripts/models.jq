[
  .[] | select(.kind == "AIServices") | .model |
  select(.format == "OpenAI" and .lifecycleStatus == "GenerallyAvailable") |
  select(.capabilities.chatCompletion == "true") |
  select(.name | test("^gpt-[0-9][a-zA-Z0-9.-]*(-mini|-nano)$")) |
  . as $model |
  .skus[] | select(.name == "Standard" or .name == "GlobalStandard") |
  select(.usageName | contains("finetune") | not) |
  {
    model: $model.name, version: $model.version, sku: .name,
    usageName: .usageName,
    suggestedCapacity: (.capacity.minimum // .capacity.default),
    maximum: .capacity.maximum,
    step: .capacity.step,
    allowed: .capacity.allowedValues
  } |
  select(.suggestedCapacity != null and .suggestedCapacity > 0)
] | unique_by([.model, .version, .sku]) | sort_by([.model, .version, .sku])
