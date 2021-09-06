local config      = require 'config'
local defaultlibs = require 'library.defaultlibs'
local define      = require 'proto.define'
local fs          = require 'bee.filesystem'
local furi        = require 'file-uri'
local json        = require 'json'
local util        = require 'utility'

local rojo = {}

rojo.Watch = {}
rojo.RojoProject = {}
rojo.LibraryCache = {}
rojo.DataModel = nil
rojo.Scripts = {}

local librariesTypes = {
    ["Roact"] = {
        textPattern = "^%s*%-%-%[%[%s*Packages up the internals of Roact and exposes a public API for it%."
    },
    ["Rodux"] = {
        textPattern = "^.-require%(script%.Store%).-require%(script%.createReducer%).-require%(script%.combineReducers%)"
    },
    ["RoactRodux"] = {
        textPattern = "return %{%s+StoreProvider %= StoreProvider%,.-connect %= connect.-%}%s*$"
    },
    ["Promise.Static"] = {
        textPattern = "^%s*%-%-%[%[%s*An implementation of Promises similar to Promise%/A%+%."
    }
}

local keys = {
    ["$className"] = true,
    ["$path"] = true,
    ["$properties"] = true,
    ["$ignoreUnknownInstances"] = true
}

function rojo:scriptClass(filename)
    if filename:match("^.+%.server%.lua$") then
        return "Script"
    elseif filename:match("^.+%.client%.lua$") then
        return "LocalScript"
    elseif filename:match("^.+%.lua$") then
        return "ModuleScript"
    end
end

local function removeLuaExtension(name)
    return name:gsub("%.server%.lua$", ""):gsub("%.client%.lua$", ""):gsub("%.lua$", "")
end

local function inspectModel(model)
    if not model.Children then
        return
    end
    local tree = {}
    pcall(function()
        for _, child in pairs(model.Children) do
            if child.Name and child.ClassName then
                tree[child.Name] = {
                    name = child.Name,
                    type = "type.library",
                    kind = "child",
                    value = {
                        [1] = child.ClassName,
                        type = "type.name",
                        child = inspectModel(child)
                    }
                }
            end
        end
    end)
    return tree
end

local function searchFile(parent, filePath)
    local path = fs.current_path() / filePath
    if not path then
        return
    end
    if fs.is_directory(path) then
        parent.value[1] = "Folder"
        for childPath in path:list_directory() do
            local childName = tostring(childPath:filename())
            if rojo:scriptClass(childName) then
                local name = removeLuaExtension(childName)
                if name == "init" then
                    parent.value[1] = rojo:scriptClass(childName)
                    parent.value.uri = furi.encode(childPath:string())
                    rojo.Scripts[parent.value.uri] = parent.value
                else
                    local child = {
                        name = name,
                        type = "type.library",
                        kind = "child",
                        value = {
                            [1] = rojo:scriptClass(childName),
                            type = "type.name",
                            uri = furi.encode(childPath:string())
                        }
                    }
                    parent.value.child[name] = child
                    rojo.Scripts[child.value.uri] = child.value
                end
            elseif fs.is_directory(childPath) then
                local child = {
                    name = childName,
                    type = "type.library",
                    kind = "child",
                    value = {
                        [1] = "Folder",
                        type = "type.name",
                        child = {}
                    }
                }
                searchFile(child, filePath .. "/" .. childName)
                parent.value.child[childName] = child
            elseif childName == "init.meta.json" then
                local success, meta = pcall(json.decode, util.loadFile(childPath))
                if success and meta.className then
                    parent.value[1] = meta.className
                end
            elseif childName:match("%.model%.json$") then
                local name = childName:gsub("%.model%.json$", "")
                local success, model = pcall(json.decode, util.loadFile(childPath))
                if success then
                    parent.value.child[name] = {
                        name = name,
                        type = "type.library",
                        kind = "child",
                        value = {
                            [1] = model.ClassName,
                            type = "type.name",
                            child = inspectModel(model)
                        }
                    }
                end
            elseif childName:match("%.txt$") then
                local name = childName:gsub("%.txt$", "")
                parent.value.child[name] = {
                    name = name,
                    type = "type.library",
                    kind = "child",
                    value = {
                        [1] = "StringValue",
                        type = "type.name",
                    }
                }
            elseif childName:match("%.csv$") then
                local name = childName:gsub("%.csv$", "")
                parent.value.child[name] = {
                    name = name,
                    type = "type.library",
                    kind = "child",
                    value = {
                        [1] = "LocalizationTable",
                        type = "type.name",
                    }
                }
            elseif childName:match("%.json$") and not childName:match("%.meta%.json$")  then
                local name = childName:gsub("%.json$", "")
                parent.value.child[name] = {
                    name = name,
                    type = "type.library",
                    kind = "child",
                    value = {
                        [1] = "ModuleScript",
                        type = "type.name",
                    }
                }
            end
        end
    else
        local name = tostring(path:filename())
        if rojo:scriptClass(name) then
            parent.value[1] = rojo:scriptClass(name)
            parent.value.uri = furi.encode(path:string())
            rojo.Scripts[parent.value.uri] = parent.value
        elseif name:match("%.model%.json$") then
            local success, model = pcall(json.decode, util.loadFile(path))
            if success then
                parent.value[1] =  model.ClassName
                local modelChildren = inspectModel(model)
                if modelChildren then
                    parent.value.child = parent.value.child or {}
                    util.mergeTable(parent.value.child, modelChildren)
                end
            end
        elseif name:match("%.txt$") then
            parent.value[1] = "StringValue"
        elseif name:match("%.csv$") then
            parent.value[1] = "LocalizationTable"
        elseif name:match("%.json$") and not name:match("%.meta%.json$")  then
            parent.value[1] = "ModuleScript"
        end
    end
end

local function normalizePath(path)
    return path:gsub("[/\\]+", "/"):gsub("/$", ""):gsub("^%.%/", "")
end

local function getChildren(parent, name, tree, path)
    if name then
        path = path .. "/" .. name
    end
    local obj = {
        name = name,
        type = "type.library",
        kind = "child",
        value = {
            [1] = "Instance",
            type = "type.name",
            child = {}
        }
    }
    if tree["$path"] then
        local filePath = normalizePath(tree["$path"])
        rojo.Watch[#rojo.Watch+1] = filePath
        searchFile(obj, filePath)
    end
    if tree["$className"] then
        obj.value[1] = tree["$className"]
    end
    for _name, child in pairs(tree) do
        if _name:sub(1, 1) ~= "$" then
            getChildren(obj, _name, child, path)
        end
    end
    if name then
        parent.value.child[name] = obj
    else
        parent.value = obj.value
    end
end

function rojo:matchLibrary(uri)
    if uri:match("%.spec%.lua$") then
        return nil
    end
    local cache = rojo.LibraryCache[uri]
    if cache ~= nil then
        if cache == false then
            return nil
        end
        return cache
    end
    local text = util.loadFile(furi.decode(uri))
    for tp, info in pairs(librariesTypes) do
        if text:match(info.textPattern) then
            rojo.LibraryCache[uri] = {
                [1] = tp,
                type = "type.name",
                typeAlias = defaultlibs.customType[tp]
            }
            return rojo.LibraryCache[uri]
        end
    end
    rojo.LibraryCache[uri] = false
    return nil
end

function rojo:projectChanged(change)
    local projectFileName = config.config.workspace.rojoProjectFile
    if change.uri:match(projectFileName .. "%.project%.json$") then
        return true
    else
        local path = furi.decode(change.uri)
        if path then
            local filename = fs.path(path):filename():string()
            if change.type == define.FileChangeType.Changed
            and filename ~= "init.meta.json"
            and not filename:match("%.model%.json$") then
                return false
            end
            return self:findScriptInProject(change.uri)
        end
    end
end

function rojo:findScriptInProject(uri)
    if not self.RojoProject then
        return true
    end
    for _, path in pairs(self.Watch) do
        if uri:match(path) then
            return true
        end
    end
end

function rojo:updateDatamodel(datamodel)
    self.DataModel = inspectModel(datamodel)
end

function rojo:loadRojoProject()
    self.LibraryCache = {}
    self.RojoProject = {}
    self.Watch = {}
    self.Scripts = {}
    if config.config.workspace.rojoProjectFile ~= "" then
        local filename = config.config.workspace.rojoProjectFile .. ".project.json"
        if fs.exists(fs.current_path() / filename) then
            local success, project = pcall(json.decode, util.loadFile((fs.current_path() / filename):string()))
            if success and project.tree then
                self.RojoProject = {project}
            else
                return
            end
        end
    else
        for path in fs.current_path():list_directory() do
            if path:string():match("%.project%.json") then
                local success, project = pcall(json.decode, util.loadFile(path:string()))
                if success and project.tree then
                    self.RojoProject[#self.RojoProject+1] = project
                end
            end
        end
    end
    if #self.RojoProject == 0 then
        return
    end
    local mainTree = {}
    for _, project in pairs(self.RojoProject) do
        local tree = {value = {child = {}}}
        getChildren(tree, nil, project.tree, "")
        mainTree = util.mergeTable(mainTree, tree)
    end
    table.sort(self.Watch, function(a, b)
        return #a > #b
    end)
    return mainTree
end

return rojo