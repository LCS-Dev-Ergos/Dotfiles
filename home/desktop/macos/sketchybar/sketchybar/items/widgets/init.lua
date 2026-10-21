-- =====-------------------------------------------------------------------=====
-- STATUS WIDGET COMPOSITION
--
-- Load battery, audio, network, CPU, package-update and navigation-effect
-- widgets in their configured order.
-- =====-------------------------------------------------------------------=====

require("items.widgets.battery")
require("items.widgets.volume")
require("items.widgets.wifi")
require("items.widgets.cpu")
require("items.widgets.homebrew")
require("items.widgets.navigation")
