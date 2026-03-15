local HUDTheme = {}

HUDTheme.Tokens = {
    backgroundColor = Color3.fromRGB(28, 36, 46),
    gradientTop = Color3.fromRGB(34, 45, 58),
    gradientBottom = Color3.fromRGB(28, 36, 46),
    strokeColor = Color3.fromRGB(176, 196, 220),
    textColor = Color3.fromRGB(245, 252, 255),
    font = Enum.Font.GothamMedium,
    textSize = 14,
    textStrokeTransparency = 0.78,
    textStrokeColor = Color3.fromRGB(14, 18, 28),
    cornerRadius = 14,
    strokeThickness = 1.5,
    strokeTransparency = 0.34,
    backgroundTransparency = 0.2,
    inventoryButtonColor = Color3.fromRGB(41, 52, 67),
    inventoryButtonSelectedColor = Color3.fromRGB(72, 104, 148),
    inventoryButtonStrokeColor = Color3.fromRGB(164, 192, 228),
}

local function getOrCreate(parent: Instance, className: string, childName: string): Instance
    local existing = parent:FindFirstChild(childName)
    if existing and existing.ClassName == className then
        return existing
    end
    if existing then
        existing:Destroy()
    end
    local instance = Instance.new(className)
    instance.Name = childName
    instance.Parent = parent
    return instance
end

function HUDTheme.applySurface(guiObject: GuiObject, options: { [string]: any }?)
    local tokens = HUDTheme.Tokens
    local opts = options or {}
    local cornerRadius = tonumber(opts.cornerRadius) or tokens.cornerRadius
    local strokeThickness = tonumber(opts.strokeThickness) or tokens.strokeThickness
    local strokeTransparency = tonumber(opts.strokeTransparency)
    if strokeTransparency == nil then
        strokeTransparency = tokens.strokeTransparency
    end
    local backgroundTransparency = tonumber(opts.backgroundTransparency)
    if backgroundTransparency == nil then
        backgroundTransparency = tokens.backgroundTransparency
    end
    local gradientTop = opts.gradientTop or tokens.gradientTop
    local gradientBottom = opts.gradientBottom or tokens.gradientBottom
    local strokeColor = opts.strokeColor or tokens.strokeColor
    local backgroundColor = opts.backgroundColor or tokens.backgroundColor
    local rotation = tonumber(opts.gradientRotation) or 90
    local useGradient = opts.useGradient ~= false

    guiObject.BackgroundColor3 = backgroundColor
    guiObject.BackgroundTransparency = backgroundTransparency

    local corner = getOrCreate(guiObject, 'UICorner', 'ThemeCorner') :: UICorner
    corner.CornerRadius = UDim.new(0, cornerRadius)

    local stroke = getOrCreate(guiObject, 'UIStroke', 'ThemeStroke') :: UIStroke
    stroke.Color = strokeColor
    stroke.Thickness = strokeThickness
    stroke.Transparency = strokeTransparency

    local existingGradient = guiObject:FindFirstChild('ThemeGradient')
    if useGradient then
        local gradient = getOrCreate(guiObject, 'UIGradient', 'ThemeGradient') :: UIGradient
        gradient.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, gradientTop),
            ColorSequenceKeypoint.new(1, gradientBottom),
        })
        gradient.Rotation = rotation
    elseif existingGradient then
        existingGradient:Destroy()
    end
end

function HUDTheme.applyText(label: TextLabel | TextButton, options: { [string]: any }?)
    local tokens = HUDTheme.Tokens
    local opts = options or {}
    label.Font = opts.font or tokens.font
    label.TextSize = tonumber(opts.textSize) or tokens.textSize
    label.TextColor3 = opts.textColor or tokens.textColor
    label.TextStrokeColor3 = opts.textStrokeColor or tokens.textStrokeColor
    local strokeTransparency = tonumber(opts.textStrokeTransparency)
    if strokeTransparency == nil then
        strokeTransparency = tokens.textStrokeTransparency
    end
    label.TextStrokeTransparency = strokeTransparency
    label.TextTransparency = tonumber(opts.textTransparency) or 0
    if opts.textXAlignment then
        label.TextXAlignment = opts.textXAlignment
    end
end

function HUDTheme.applyInventoryButtonState(button: TextButton, isSelected: boolean)
    local tokens = HUDTheme.Tokens
    if isSelected then
        HUDTheme.applySurface(button, {
            backgroundColor = tokens.inventoryButtonSelectedColor,
            strokeColor = tokens.inventoryButtonStrokeColor,
            strokeThickness = 1.8,
            strokeTransparency = 0.05,
            backgroundTransparency = 0.06,
            useGradient = false,
        })
        HUDTheme.applyText(button, {
            textTransparency = 0,
            textStrokeTransparency = 0.72,
        })
    else
        HUDTheme.applySurface(button, {
            backgroundColor = tokens.inventoryButtonColor,
            strokeColor = tokens.inventoryButtonStrokeColor,
            strokeThickness = 1.2,
            strokeTransparency = 0.48,
            backgroundTransparency = 0.2,
            useGradient = false,
        })
        HUDTheme.applyText(button, {
            textTransparency = 0,
            textStrokeTransparency = 0.84,
        })
    end
end

return HUDTheme
