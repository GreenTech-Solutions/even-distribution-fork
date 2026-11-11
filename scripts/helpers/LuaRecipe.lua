local recipe = scripts.helpers
local _ = scripts.helpers.on

-- Helper functions for LuaRecipe --

function recipe:ingredientcount(item) -- get count of a specific item in recipe ingredients
    if self:is("valid") then
		for __,ingredient in pairs(self.ingredients) do
			if ingredient.name == item then return ingredient.amount end
		end
    end
    
	return 0
end

function recipe:hasIngredient(item)
    return self:ingredientcount(item) > 0
end

function recipe:hasProduct(item)
    if not self:is("valid") then return false end

    for _, product in pairs(self.products) do
        if product.type == "item" and product.name == item then
            local shared = product.shared_probability
            local maxAmount = product.amount or product.amount_max or 0
            if (product.independent_probability or 1) > 0
                and (not shared or shared.max > shared.min)
                and (maxAmount > 0 or (product.extra_count_fraction or 0) > 0) then
                return true
            end
        end
    end
    return false
end

function recipe:ingredientmap() -- ingredient table: item name --> amount
	local ingredients = {}
    
    if self:is("valid") then
        for __,ingredient in pairs(self.ingredients) do
            if ingredient.type == "item" then ingredients[ingredient.name] = ingredient.amount end
        end
	end
	
	return ingredients
end

function recipe:productmap() -- product table: item name --> amount
	local products = {}
    
    if self:is("valid") then
        for __,product in pairs(self.products) do
            if product.type == "item" then products[product.name] = product.amount end
        end
	end
	
	return products
end
