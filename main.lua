-- ------------------------------------------------------
-- Fibaro Quick App for SMA inverters
-- Author: Irek Kubicki <irek@ixdude.com>
-- v.0.1.0
-- GIT: https://github.com/ikubicki/fibaro-sma
-- ------------------------------------------------------

function QuickApp:onInit()
    self:trace("")
    self:trace("SMA Quick App starts")
    self:trace("Author: Irek Kubicki <irek@ixdude.com>")
    self:trace("GIT: https://github.com/ikubicki/fibaro-sma")
    self:trace("")

    self.devicesMap = self:getGlobal('SMAdevices', {})
    self:initDevices()

    self:updateProperty("manufacturer", "SMA")
    self:updateProperty("model", "Inverter")

    self.http = net.HTTPClient({timeout=10000})
    self.smaUrl = self:getVariable("API URL")
    self.smaRight = self:getVariable("API User")
    self.smaPass = self:getVariable("API Password")
    self.autoUpdateInterval = 5
    self.sid = false
    self.values = {}

    self.loadProperties()
    self.loadKeys()
    self:loadPhrases(api.get("/settings/info").defaultLanguage)

    self:updateView("button1", "text", self.phrases["REFRESH"])
    self:updateView("label1", "text", self.phrases["LAST_UPDATE"] .. ": -----------")
    self:updateView("label2", "text", string.format(self.phrases["AUTO_UPDATE_1"], self.autoUpdateInterval))
    self:updateView("slider1", "value", tostring(self.autoUpdateInterval))
    self:run()
end

function QuickApp:initDevices()

    self:loadDevicesMap()
    self:initChildDevices(self.smaDevicesMap)
    self:trace("Detected child devices:")

    for id, device in pairs(self.childDevices) do
        local detectedId = 'NO'
        for smaId, deviceId in pairs(self.devicesMap) do
            if (deviceId == id) then
                detectedId = smaId
            end
        end
        self:trace("[#" .. id .. "]", device.name .. ", SMAID: ", detectedId)
    end
end

function QuickApp:button1Event(event)
    self:login()
end

function QuickApp:slider1Event(event)
    self.autoUpdateInterval = event["values"][1]
    if (self.autoUpdateInterval > 0) then
        self:updateView("label2", "text", string.format(self.phrases["AUTO_UPDATE_1"], self.autoUpdateInterval))
    else
        self:updateView("label2", "text", self.phrases["AUTO_UPDATE_0"])
    end
end

function QuickApp:run()
    self:login()
    if (self.autoUpdateInterval > 0) then
        fibaro.setTimeout(self.autoUpdateInterval * 60 * 1000, function() self:run() end)
    end
end

function QuickApp:login()

    self:updateView("button1", "text", self.phrases["WAIT"])
    local parameters = {
        right = self.smaRight,
        pass = self.smaPass
    }
    self.http:request(self.smaUrl .. "/dyn/login.json", {
        options = {
            data = json.encode(parameters),
            checkCertificate = false,
            method = 'POST'
        },
        success = function (response)
            local json = json.decode(response.data)
            local sid = json.result.sid
            self.sid = sid
            self:debug("logged in as " .. sid)
            self:getValues(sid)
        end,
        error = function (error)
            self:debug('error: ' .. json.encode(error))
        end
    }) 
end

function QuickApp:getValues(sid)
    local parameters = {
        destDev = {},
        keys = self.keys
    }
    self.values = {}
    parameters = json.encode(parameters)
    parameters = string.gsub(parameters, "{}", "[]") -- tiny hack
    self.http:request(self.smaUrl .. "/dyn/getValues.json?sid=" .. sid, {
        options = {
            data = parameters,
            checkCertificate = false,
            method = 'POST'
        },
        success = function (response)
            local text = string.gsub(response.data, "null", "0") -- another hack
            local json = json.decode(text)
            -- self:debug("values", text)
            local devices = json.result
            for deviceId, v in pairs(devices) do
                for property, value in pairs(v) do
                    self.values[property] = {
                        masterDeviceId = deviceId,
                        name = self.smaProperties[property],
                        value = value["1"][1]['val']
                    }
                end
            end
            -- i found that some older units support this value
            -- but if it's not present, we can get today yield
            -- using logger, just like inverter's UI
            if (self.values["6400_00262200"] == nil) then
                -- self:debug("6400_00262200 not present in values, fetching logger.")
                self:getYield(sid)
            else
                self:logout(sid)
                self:createDevices()
            end
        end,
        error = function (error)
            self:error(json.encode(error))
            self:logout(sid)
        end
    }) 
    
end

function QuickApp:getYield(sid)
    local midnight = os.time({year = os.date("%Y"), month = os.date("%m"), day = os.date("%d"), hour = 0, min = 0})
    local parameters = {
        destDev = {},
        key = 28672,
        tStart = midnight,
        tEnd = midnight + 86400
    }
    parameters = json.encode(parameters)
    parameters = string.gsub(parameters, "{}", "[]") -- tiny hack
    self.http:request(self.smaUrl .. "/dyn/getLogger.json?sid=" .. sid, {
        options = {
            data = parameters,
            checkCertificate = false,
            method = 'POST'
        },
        success = function (response)
            -- self:trace(json.encode(response.data))
            local json = json.decode(response.data)
            self:logout(sid)
            local devices = json.result
            for deviceId, v in pairs(devices) do
                local property = "6400_00262200"
                local yield = v[#v]['v'] - v[1]['v']
                self.values[property] = {
                    masterDeviceId = deviceId,
                    name = self.smaProperties[property],
                    value = yield
                }
                self:createDevices()
            end
        end,
        error = function (error)
            self:error(json.encode(error))
            self:logout(sid)
        end
    }) 
end

function QuickApp:logout(sid)
    self:updateView("button1", "text", self.phrases["REFRESH"])
    self.http:request(self.smaUrl .. "/dyn/logout.json?sid=" .. sid, {
        options = {
            data = json.encode({}),
            checkCertificate = false,
            method = 'POST'
        },
        success = function (response)
            local json = json.decode(response.data)
            -- self:debug(response.data)
            if (json.result.isLogin == false) then
                self:debug(sid .. " successfully logged out")
                self.sid = false
            end
        end,
        error = function (error)
            self:error(json.encode(error))
        end
    })
end

function QuickApp:createDevices()
    for property, data in pairs(self.values) do
        local name = self.phrases["NAMES"][self.smaProperties[property]]
        if (not name) then
            name = self.smaProperties[property]
        end
        if (not name) then
            name = property
        end
        local type = "com.fibaro.multilevelSensor"
        local data = self.values[property]
        local child = self:addSMAChildDevice(property, name, type)
        child:updateProperty("unit", self:getUnit(property))
        child:updateProperty("value", data.value)
    end
    self:updateView("label1", "text", self.phrases["LAST_UPDATE"] .. ": " .. os.date("%Y-%m-%d %H:%M:%S"))
end

function QuickApp:addSMAChildDevice(id, name, type)
    -- look for devices in global map
    if (self.devicesMap[id] ~= nil) then
        local childId = self.devicesMap[id .. 'a']
        if (self.childDevices[childId] ~= nil) then
            return self.childDevices[childId]
        end
    end
    -- match by name
    for childDeviceId, childDevice in pairs(self.childDevices) do
        if (childDevice.name == name) then
            return childDevice
        end
    end
    -- create new child device
    local child = self:createChildDevice({
        name = name,
        type = type
    }, self.smaDevicesMap[type])

    local parentRoomID = api.get('/devices/' .. self.id).roomID
    api.put('/devices/' .. child.id, {
        ["roomID"] = parentRoomID
    })

    self:storeDevice(id, child.id)
    self:trace("Child device created: [#" .. child.id .. "]", child.name .. ", SMAID:", id)
    return child
end

function QuickApp:storeDevice(deviceNativeName, deviceId)
    self.devicesMap[deviceNativeName] = deviceId
    self:setGlobal('SMAdevices', self.devicesMap)
end

function QuickApp:getGlobal(name, alternative)
    local response = api.get('/globalVariables/' .. name)
    if (response) then
        if (string.sub(response.value, 1, 1) == '{') then
            return json.decode(response.value)
        end
        return response.value
    end

    return alternative
end

function QuickApp:setGlobal(name, value)
    local response = api.put('/globalVariables/' .. name, {
        name = name,
        value = json.encode(value)
    })
    if not response then
        local response = api.post('/globalVariables', {
            name = name,
            value = json.encode(value)
        })
    end
    self:debug(json.encode(response))
end

-- ---------------------------------
-- Dictionaries
-- ---------------------------------

function QuickApp:loadDevicesMap()
    QuickApp.smaDevicesMap = {
        ["com.fibaro.multilevelSensor"] = SMAMeter,
    }
end

function QuickApp:loadKeys()
    QuickApp.keys = {
        "6100_00411E00",
        "6100_40263F00",
        "6400_00260100",
        "6400_00262200"
    }
end

function QuickApp:getUnit(property)
    local units = {
        ["6100_00411E00"] = "W",
        ["6100_40263F00"] = "W",
        ["6400_00260100"] = "Wh",
        ["6400_00262200"] = "Wh"
    }
    return units[property]
end

function QuickApp:loadProperties()
    QuickApp.smaProperties = {
        ["6100_00411E00"] = "power_maximum",
        ["6100_40263F00"] = "power_current",
        ["6400_00260100"] = "yield_total",
        ["6400_00262200"] = "yield_today"
    }
end

function QuickApp:loadPhrases(lang)
    local phrases = {
        en = {
            REFRESH = "Refresh metrics",
            WAIT = "Please wait...",
            LAST_UPDATE = "Last update",
            AUTO_UPDATE_0 = "Auto update is disabled",
            AUTO_UPDATE_1 = "Auto update every %d minutes",
            NAMES = {
                ["power_maximum"] = "PV system power",
                ["power_current"] = "Current PV Power",
                ["yield_today"] = "PV Energy",
                ["yield_total"] = "Total PV energy"
            }
        },
        pl = {
            REFRESH = "Odśwież dane",
            WAIT = "Proszę czekać...",
            LAST_UPDATE = "Ostatnia aktualizacja",
            AUTO_UPDATE_0 = "Automatyczna aktualizacja jest wyłączona",
            AUTO_UPDATE_1 = "Automatyczna aktualizacja co %s minut",
            NAMES = {
                ["power_maximum"] = "Moc instalacji",
                ["power_current"] = "Aktualna moc PV",
                ["yield_today"] = "Energia fotowoltaiczna",
                ["yield_total"] = "Całkowita energia fotowoltaiczna"
            }
        },
        de = {
            REFRESH = "Daten aktualisieren",
            WAIT = "Ein moment bitte...",
            LAST_UPDATE = "Letzte aktualisierung",
            AUTO_UPDATE_0 = "Die automatische Aktualisierung ist deaktiviert",
            AUTO_UPDATE_1 = "Automatische Aktualisierung alle %s Minuten",
            NAMES = {
                ["power_maximum"] = "Anlagenleistung",
                ["power_current"] = "Aktuelle PV-Leistung",
                ["yield_today"] = "PV-Energie",
                ["yield_total"] = "PV-Energie gesamt"
            }
        }
    }
    if (phrases[lang] == nil) then
        QuickApp.phrases = phrases["en"]
    else
        QuickApp.phrases = phrases[lang]
    end
end

-- ----------------------------------------
-- Class definition for child devices
-- ----------------------------------------

class 'SMAMeter' (QuickAppChild)
function SMAMeter:__init(device)
    QuickAppChild.__init(self, device)
end

function SMAMeter:getProperty(name)
    local value = fibaro.getValue(self.id, name)
    return value
end