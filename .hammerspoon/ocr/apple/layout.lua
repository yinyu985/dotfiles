-- Rebuild reading order from Apple Vision's normalized bounding boxes.
-- Plain text stays line-oriented; stable multi-column regions become TSV.
local M = {}

local function median(values)
    if #values == 0 then return 0 end
    table.sort(values)
    local middle = math.floor((#values + 1) / 2)
    if #values % 2 == 1 then return values[middle] end
    return (values[middle] + values[middle + 1]) / 2
end

local function finiteNumber(value)
    local number = tonumber(value)
    if number and number == number and number ~= math.huge and number ~= -math.huge then
        return number
    end
end

local function textMetrics(text)
    if utf8 and utf8.codes then
        local ok, count, first, last = pcall(function()
            local length, head, tail = 0, nil, nil
            for _, codepoint in utf8.codes(text) do
                length = length + 1
                head, tail = head or codepoint, codepoint
            end
            return length, head, tail
        end)
        if ok then return count, first, last end
    end
    return #text, text:byte(1), text:byte(-1)
end

local function normalizedItems(items)
    local result = {}
    for _, value in ipairs(type(items) == "table" and items or {}) do
        local raw = type(value) == "table" and value or {}
        local text = type(raw.text) == "string" and raw.text:gsub("^%s+", ""):gsub("%s+$", "") or ""
        local x, y = finiteNumber(raw.x), finiteNumber(raw.y)
        local width, height = finiteNumber(raw.width), finiteNumber(raw.height)
        if text ~= "" and x and y and width and height and width >= 0 and height > 0 then
            local length, first, last = textMetrics(text)
            result[#result + 1] = {
                text = text,
                confidence = finiteNumber(raw.confidence) or 0,
                charWidth = width / math.max(length, 1),
                firstCodepoint = first,
                lastCodepoint = last,
                characters = type(raw.characters) == "table" and raw.characters or nil,
                x = x,
                y = y,
                width = width,
                height = height,
                right = x + width,
                top = y + height,
                centerX = x + width / 2,
                centerY = y + height / 2,
            }
        end
    end
    return result
end

local function makeRows(items)
    local heights, maximumHeight = {}, 0
    for _, item in ipairs(items) do
        heights[#heights + 1] = item.height
        maximumHeight = math.max(maximumHeight, item.height)
    end
    local medianHeight = median(heights)

    table.sort(items, function(a, b)
        if a.centerY ~= b.centerY then return a.centerY > b.centerY end
        if a.x ~= b.x then return a.x < b.x end
        return a.text < b.text
    end)

    local rows, activeRows = {}, {}
    for _, item in ipairs(items) do
        local bestRow, bestScore, nearbyRows = nil, nil, {}
        for _, row in ipairs(activeRows) do
            local centerDelta = math.abs(item.centerY - row.centerY)
            -- Centers arrive top-to-bottom. Beyond this bound, no later item
            -- can join the row, even at the largest observed text height.
            if centerDelta <= maximumHeight * 0.72 then
                nearbyRows[#nearbyRows + 1] = row
                local overlap = math.max(0, math.min(item.top, row.top) - math.max(item.y, row.bottom))
                local overlapRatio = overlap / math.max(0.000001, math.min(item.height, row.height))
                -- A large title must not widen the tolerance for small body text.
                local closeCenters = centerDelta <= math.min(item.height, row.height) * 0.55
                local sameLine = closeCenters or (overlapRatio >= 0.35
                    and centerDelta <= math.max(item.height, row.height) * 0.72)
                if sameLine then
                    local score = overlapRatio - centerDelta
                    if not bestScore or score > bestScore then
                        bestRow, bestScore = row, score
                    end
                end
            end
        end
        activeRows = nearbyRows

        if not bestRow then
            local row = {
                items = { item },
                centerY = item.centerY,
                centers = { item.centerY },
                heights = { item.height },
                bottom = item.y,
                top = item.top,
                height = item.height,
            }
            rows[#rows + 1] = row
            activeRows[#activeRows + 1] = row
        else
            bestRow.items[#bestRow.items + 1] = item
            bestRow.centers[#bestRow.centers + 1] = item.centerY
            bestRow.heights[#bestRow.heights + 1] = item.height
            -- Representative bounds prevent a growing union box from swallowing
            -- the next line after a slightly offset fragment joins this one.
            bestRow.centerY = median(bestRow.centers)
            bestRow.height = median(bestRow.heights)
            bestRow.bottom = bestRow.centerY - bestRow.height / 2
            bestRow.top = bestRow.centerY + bestRow.height / 2
        end
    end

    table.sort(rows, function(a, b) return a.centerY > b.centerY end)
    for _, row in ipairs(rows) do
        table.sort(row.items, function(a, b)
            if a.x ~= b.x then return a.x < b.x end
            if a.centerY ~= b.centerY then return a.centerY > b.centerY end
            return a.text < b.text
        end)
    end
    return rows, medianHeight
end

local function boundariesFor(row)
    local boundaries = {}
    for i = 1, #row.items - 1 do
        local left, right = row.items[i], row.items[i + 1]
        -- A center midpoint can cut through a wide header and shift right-aligned
        -- values into the next column. Prefer the actual gap between headers.
        boundaries[i] = left.right <= right.x and (left.right + right.x) / 2
            or (left.centerX + right.centerX) / 2
    end
    return boundaries
end

local function columnFor(item, boundaries)
    for i, boundary in ipairs(boundaries) do
        if item.centerX < boundary then return i end
    end
    return #boundaries + 1
end

local function isCJK(codepoint)
    if not codepoint then return false end
    return (codepoint >= 0x3400 and codepoint <= 0x9FFF)
        or (codepoint >= 0xF900 and codepoint <= 0xFAFF)
        or (codepoint >= 0x20000 and codepoint <= 0x323AF)
        or (codepoint >= 0x3040 and codepoint <= 0x30FF)
end

local openingPunctuation = {
    [0x28] = true, [0x5B] = true, [0x7B] = true, -- ([{
    [0x2018] = true, [0x201C] = true, [0x3008] = true, [0x300A] = true,
    [0x300C] = true, [0x300E] = true, [0x3010] = true, [0xFF08] = true,
}
local closingPunctuation = {
    [0x29] = true, [0x5D] = true, [0x7D] = true, -- )]}
    [0x2C] = true, [0x2E] = true, [0x3A] = true, [0x3B] = true,
    [0x21] = true, [0x3F] = true, [0x25] = true,
    [0x2019] = true, [0x201D] = true, [0x3001] = true, [0x3002] = true,
    [0x3009] = true, [0x300B] = true, [0x300D] = true, [0x300F] = true,
    [0x3011] = true, [0xFF09] = true, [0xFF0C] = true, [0xFF0E] = true,
    [0xFF1A] = true, [0xFF1B] = true, [0xFF01] = true, [0xFF1F] = true,
}

local function isCJKBoundary(codepoint)
    return isCJK(codepoint) or (codepoint and codepoint >= 0x2000
        and (openingPunctuation[codepoint] or closingPunctuation[codepoint]))
end

local function adjacentSeparator(left, right)
    local gap = right.x - left.right
    local tightGap = math.max((left.charWidth + right.charWidth) * 0.4,
        math.min(left.height, right.height) * 0.5)
    if gap <= tightGap and (openingPunctuation[left.lastCodepoint]
        or closingPunctuation[right.firstCodepoint]
        or (isCJKBoundary(left.lastCodepoint) and isCJKBoundary(right.firstCodepoint))) then
        return ""
    end
    return " "
end

local function numericText(text)
    return text:gsub("[%s,]", ""):gsub("−", "-"):gsub("％", "%%")
        :gsub("[%$]", ""):gsub("€", ""):gsub("¥", ""):gsub("£", "")
end

local function singleNumber(text)
    local normalized = numericText(text):gsub("^%((.*)%)$", "-%1")
    return normalized:match("^[+-]?%d+%.?%d*%%?$") or normalized:match("^[+-]?%.%d+%%?$")
end

local function characterUnits(item, mode)
    local tokens, word, wordCount = {}, nil, 0
    for _, character in ipairs(item.characters) do
        if type(character) ~= "table" or type(character.text) ~= "string" then return nil end
        if character.text:match("^%s+$") then
            tokens[#tokens + 1], word = character, nil
        elseif character.text ~= "" then
            local x, y = finiteNumber(character.x), finiteNumber(character.y)
            local width, height = finiteNumber(character.width), finiteNumber(character.height)
            if not x or not y or not width or not height or width <= 0 or height <= 0 then return nil end
            if not word then
                word = { text = character.text, x = x, y = y, width = width, height = height }
                tokens[#tokens + 1], wordCount = word, wordCount + 1
            else
                local right, top = math.max(word.x + word.width, x + width), math.max(word.y + word.height, y + height)
                word.x, word.y = math.min(word.x, x), math.min(word.y, y)
                word.width, word.height = right - word.x, top - word.y
                word.text = word.text .. character.text
            end
        end
    end
    -- Whitespace separates whole words more reliably than the left/right edges
    -- of a differently aligned header. Keep unspaced header words intact.
    if wordCount > 1 then return tokens end
    if mode == "header" then return nil end
    -- A grid boundary alone must never cut a URL, identifier, date, word, or
    -- one long number. Only an otherwise numeric multi-value string with an
    -- explicit percentage marker is eligible for character-level recovery.
    local numeric = numericText(item.text)
    if not numeric:find("%%") or numeric:find("[^%d%.%+%-%%%(%)]") or singleNumber(numeric) then return nil end
    return item.characters, true
end

local function splitAcrossColumns(item, boundaries, mode)
    if not item.characters or columnFor({ centerX = item.x }, boundaries)
        == columnFor({ centerX = item.right }, boundaries) then return { item } end

    local units, numericSplit = characterUnits(item, mode)
    if not units then return { item } end
    local groups, current, whitespace, original = {}, nil, "", {}
    for _, character in ipairs(units) do
        if type(character) ~= "table" or type(character.text) ~= "string" then return { item } end
        local text = character.text
        original[#original + 1] = text
        if text:match("^%s+$") then
            whitespace = whitespace .. text
        elseif text ~= "" then
            local x, y = finiteNumber(character.x), finiteNumber(character.y)
            local width, height = finiteNumber(character.width), finiteNumber(character.height)
            if not x or not y or not width or not height or width <= 0 or height <= 0 then
                return { item }
            end
            local column = columnFor({ centerX = x + width / 2 }, boundaries)
            if current and column < current.column then return { item } end
            if not current or current.column ~= column then
                current = { text = text, x = x, y = y, right = x + width,
                    top = y + height, column = column, confidence = item.confidence }
                groups[#groups + 1] = current
            else
                current.text = current.text .. whitespace .. text
                current.x, current.y = math.min(current.x, x), math.min(current.y, y)
                current.right, current.top = math.max(current.right, x + width), math.max(current.top, y + height)
            end
            whitespace = ""
        end
    end
    -- If the helper could not supply every character, retain the original text.
    local reconstructed = table.concat(original):gsub("^%s+", ""):gsub("%s+$", "")
    if reconstructed ~= item.text or #groups <= 1 then return { item } end
    local originalColumn = columnFor(item, boundaries)
    for _, group in ipairs(groups) do
        if numericSplit and not singleNumber(group.text) then return { item } end
        -- A natural-language sentence can legitimately extend across a learned
        -- boundary into an empty neighboring cell. Move body tokens only when
        -- newly populated cells contain complete numbers, not arbitrary words.
        if mode == "body" and not numericSplit and group.column ~= originalColumn
            and not singleNumber(group.text) then return { item } end
        group.width, group.height = group.right - group.x, group.top - group.y
    end
    return normalizedItems(groups)
end

local function cellText(items)
    if #items == 0 then return "" end
    if #items == 1 then return items[1].text end
    table.sort(items, function(a, b)
        if a.centerY ~= b.centerY then return a.centerY > b.centerY end
        return a.x < b.x
    end)
    local lines, line = {}, nil
    for _, item in ipairs(items) do
        if not line or line.centerY - item.centerY > math.min(line.height, item.height) * 0.45 then
            line = { items = {}, centerY = item.centerY, height = item.height }
            lines[#lines + 1] = line
        end
        line.items[#line.items + 1] = item
    end
    local parts, previous
    parts = {}
    for _, textLine in ipairs(lines) do
        table.sort(textLine.items, function(a, b) return a.x < b.x end)
        for index, item in ipairs(textLine.items) do
            if previous then
                parts[#parts + 1] = index == 1 and
                    (isCJKBoundary(previous.lastCodepoint) and isCJKBoundary(item.firstCodepoint) and "" or " ")
                    or adjacentSeparator(previous, item)
            end
            parts[#parts + 1], previous = item.text, item
        end
    end
    return table.concat(parts)
end

local function mappedRow(row, boundaries, columnCount, splitCharacters)
    local cells, occupied, contents, collisions = {}, {}, {}, 0
    local originalOccupancy = {}
    for i = 1, columnCount do contents[i] = {} end
    for _, item in ipairs(row.items) do
        local column = columnFor(item, boundaries)
        originalOccupancy[column] = (originalOccupancy[column] or 0) + 1
    end
    for _, item in ipairs(row.items) do
        local fragments = splitCharacters and splitAcrossColumns(item, boundaries, splitCharacters) or { item }
        if splitCharacters == "body" and #fragments > 1 then
            local originalColumn = columnFor(item, boundaries)
            for _, fragment in ipairs(fragments) do
                local column = columnFor(fragment, boundaries)
                if (originalOccupancy[column] or 0) > (column == originalColumn and 1 or 0) then
                    fragments = { item }
                    break
                end
            end
        end
        for _, fragment in ipairs(fragments) do
            local column = columnFor(fragment, boundaries)
            if occupied[column] then collisions = collisions + 1 end
            occupied[column] = true
            contents[column][#contents[column] + 1] = fragment
        end
    end
    for column, fragments in ipairs(contents) do cells[column] = cellText(fragments) end
    local occupiedCount = 0
    for _ in pairs(occupied) do occupiedCount = occupiedCount + 1 end
    return cells, occupiedCount, collisions
end

local function rowHasNumber(row)
    for _, item in ipairs(row.items) do
        if singleNumber(item.text) then return true end
    end
    return false
end

local function findTable(rows, medianHeight)
    local best
    for headerIndex, header in ipairs(rows) do
        local columnCount = #header.items
        if columnCount >= 3 and headerIndex < #rows then
            local boundaries = boundariesFor(header)
            local boundarySamples = {}
            for index, boundary in ipairs(boundaries) do boundarySamples[index] = { boundary } end
            local aligned, lastIndex, previousY = 0, headerIndex, header.centerY
            for rowIndex = headerIndex + 1, #rows do
                local row = rows[rowIndex]
                local gap = previousY - row.centerY
                if gap > math.max(medianHeight * 4.5, 0.035) then break end
                local _, occupied, collisions = mappedRow(row, boundaries, columnCount)
                local minimumOccupied = math.max(2, math.ceil(columnCount * 0.6))
                if occupied >= minimumOccupied and collisions <= math.max(1, math.floor(#row.items * 0.25)) then
                    aligned = aligned + 1
                    lastIndex = rowIndex
                    previousY = row.centerY
                    if #row.items == columnCount and collisions == 0 then
                        for index, boundary in ipairs(boundariesFor(row)) do
                            boundarySamples[index][#boundarySamples[index] + 1] = boundary
                        end
                    end
                else
                    break
                end
            end
            if aligned >= 2 then
                for index, samples in ipairs(boundarySamples) do boundaries[index] = median(samples) end
                -- Repeated body rows are stronger evidence than a header split
                -- into many OCR fragments. Penalize unused columns and collisions.
                local score = 0
                for rowIndex = headerIndex, lastIndex do
                    local _, occupied, collisions = mappedRow(rows[rowIndex], boundaries, columnCount)
                    score = score + occupied - (columnCount - occupied) - collisions * 2
                end
                if not best or score > best.score then
                    best = {
                        first = headerIndex,
                        bodyFirst = headerIndex,
                        last = lastIndex,
                        boundaries = boundaries,
                        columnCount = columnCount,
                        score = score,
                    }
                end
            end
        end
    end
    if best then
        -- Absorb nearby multi-line headers using the stable body columns. Stop
        -- before isolated titles and more distant toolbars or summary sections.
        while best.first > 1 do
            local previous, current = rows[best.first - 1], rows[best.first]
            if previous.centerY - current.centerY > math.max(medianHeight * 2.5, 0.015) then break end
            local _, occupied, collisions = mappedRow(previous, best.boundaries, best.columnCount)
            local numeric = rowHasNumber(previous)
            local minimumOccupied = numeric and math.max(2, math.ceil(best.columnCount * 0.6)) or 2
            if occupied < minimumOccupied or collisions > math.max(2, math.floor(#previous.items * 0.5)) then break end
            best.first = best.first - 1
            if numeric then best.bodyFirst = best.first end
        end
        -- A tightly stacked leading label block can contain the same number of
        -- fragments as the body. Its shorter line spacing still distinguishes
        -- it from at least three regularly spaced body rows.
        if best.last - best.first >= 4 then
            local gaps = {}
            for index = best.first, best.last - 1 do
                gaps[#gaps + 1] = rows[index].centerY - rows[index + 1].centerY
            end
            local normalGap, headerEnd = median(gaps), best.first
            while headerEnd < best.last - 2
                and not rowHasNumber(rows[headerEnd]) and not rowHasNumber(rows[headerEnd + 1])
                and rows[headerEnd].centerY - rows[headerEnd + 1].centerY < normalGap * 0.7 do
                headerEnd = headerEnd + 1
            end
            local numericBodyRows = 0
            for index = headerEnd + 1, best.last do
                if rowHasNumber(rows[index]) then numericBodyRows = numericBodyRows + 1 end
            end
            if headerEnd > best.first and numericBodyRows >= 3 then
                best.bodyFirst = math.max(best.bodyFirst, headerEnd + 1)
            end
        end
    end
    return best
end

local function plainRow(row)
    if #row.items == 1 then return row.items[1].text end

    local charWidths = {}
    for _, item in ipairs(row.items) do
        charWidths[#charWidths + 1] = item.charWidth
    end
    local typicalCharWidth = median(charWidths)
    local parts = { row.items[1].text }
    for i = 2, #row.items do
        local gap = row.items[i].x - row.items[i - 1].right
        local separator = gap > math.max(typicalCharWidth * 2.5, 0.008) and "\t"
            or adjacentSeparator(row.items[i - 1], row.items[i])
        parts[#parts + 1] = separator
        parts[#parts + 1] = row.items[i].text
    end
    return table.concat(parts)
end

local function hasLetters(item)
    if item.text:find("%a") then return true end
    if utf8 and utf8.codes then
        local ok, found = pcall(function()
            for _, codepoint in utf8.codes(item.text) do
                if isCJK(codepoint) then return true end
            end
            return false
        end)
        return not ok or found
    end
    return item.text:find("[\128-\255]") ~= nil
end

local function findSummaries(rows, medianHeight, tableRegion)
    local summaries, covered, maximumColumns = {}, {}, 0
    local function inTable(index)
        return tableRegion and index >= tableRegion.first and index <= tableRegion.last
    end
    for valueIndex, values in ipairs(rows) do
        local numeric = #values.items >= 3 and not inTable(valueIndex)
        for _, item in ipairs(values.items) do
            if not item.text:find("%d") or hasLetters(item) then numeric = false end
        end
        if numeric then
            local labels, previousY = {}, values.centerY
            for labelIndex = valueIndex - 1, math.max(1, valueIndex - 2), -1 do
                local labelRow, textOnly = rows[labelIndex], true
                if inTable(labelIndex) or previousY - labelRow.centerY > 0
                    or labelRow.centerY - previousY > medianHeight * 1.8 then break end
                for _, label in ipairs(labelRow.items) do
                    if label.text:find("%d") or not hasLetters(label) then textOnly = false end
                end
                if not textOnly then break end
                for _, label in ipairs(labelRow.items) do labels[#labels + 1] = label end
                previousY = labelRow.centerY
                if #labels >= #values.items and #values.items >= #labels * 0.75 then
                    table.sort(labels, function(a, b) return a.x < b.x end)
                    local cells, valid = {}, true
                    for index, label in ipairs(labels) do
                        cells[index] = ""
                        if labels[index + 1] and label.right > labels[index + 1].x then valid = false end
                    end
                    for _, value in ipairs(values.items) do
                        local matched
                        for index, label in ipairs(labels) do
                            local tolerance = math.max(math.min(value.height, label.height) * 0.4, 0.002)
                            if math.abs(value.x - label.x) <= tolerance then
                                if matched or cells[index] ~= ""
                                    or (labels[index + 1] and value.right > labels[index + 1].x) then
                                    valid = false
                                end
                                matched = index
                            end
                        end
                        if not matched then valid = false else cells[matched] = value.text end
                    end
                    if valid then
                        local headings = {}
                        for index, label in ipairs(labels) do headings[index] = label.text end
                        summaries[labelIndex] = { headings = headings, cells = cells }
                        for index = labelIndex, valueIndex do covered[index] = true end
                        maximumColumns = math.max(maximumColumns, #labels)
                        break
                    end
                end
            end
        end
    end
    return summaries, covered, maximumColumns
end

function M.format(items)
    local normalized = normalizedItems(items)
    if #normalized == 0 then return "", { items = 0, rows = 0, columns = 0 } end

    local rows, medianHeight = makeRows(normalized)
    local tableRegion = findTable(rows, medianHeight)
    local summaries, summaryRows, summaryColumns = findSummaries(rows, medianHeight, tableRegion)
    local lines = {}
    for rowIndex, row in ipairs(rows) do
        local summary = summaries[rowIndex]
        if summary then
            lines[#lines + 1] = table.concat(summary.headings, "\t")
            lines[#lines + 1] = table.concat(summary.cells, "\t")
        elseif summaryRows[rowIndex] then
            -- Emitted with its aligned labels at the start of the summary block.
        elseif tableRegion and rowIndex >= tableRegion.first and rowIndex <= tableRegion.last then
            if rowIndex < tableRegion.bodyFirst then
                if rowIndex == tableRegion.first then
                    local header = { items = {} }
                    for index = tableRegion.first, tableRegion.bodyFirst - 1 do
                        for _, item in ipairs(rows[index].items) do header.items[#header.items + 1] = item end
                    end
                    local cells = mappedRow(header, tableRegion.boundaries, tableRegion.columnCount, "header")
                    lines[#lines + 1] = table.concat(cells, "\t")
                end
            else
                local cells = mappedRow(row, tableRegion.boundaries, tableRegion.columnCount, "body")
                lines[#lines + 1] = table.concat(cells, "\t")
            end
        else
            lines[#lines + 1] = plainRow(row)
        end
    end

    return table.concat(lines, "\n"), {
        items = #normalized,
        rows = #lines,
        columns = tableRegion and tableRegion.columnCount or summaryColumns,
    }
end

return M
