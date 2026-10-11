import { registerIsland, startIslands } from "./mount"
import { AiSettings } from "./ai_settings/AiSettings"
import { ProductTour } from "./product_tour/ProductTour"
import { FileField } from "./file_field/FileField"

registerIsland("ai-settings", AiSettings)
registerIsland("product-tour", ProductTour)
registerIsland("file-field", FileField)
startIslands()
