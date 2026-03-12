# Home Assistant

## Energy Monitoring — Solar + Battery

### Hardware setup

- EmonTx4 + EmonBase (IP: `192.168.88.237`)
- Mosquitto MQTT broker on EmonBase
- Solar panels, LiFePo4 custom battery pack (no BMS), inverter (~50W parasitic absorption)

### MQTT topics

| Topic | Description | Unit |
|---|---|---|
| `emon/emonTx4_17/P2` | House load | W |
| `emon/emonTx4_17/P3` | Grid import (always ≥ 0, no export — batteries absorb excess) | W |
| `emon/system/solar-power` | Solar production | W |

### Energy flow model

```
AC balance:  Inverter_AC_out = P_house - P_grid
DC balance:  Inverter_DC_in  = Inverter_AC_out + 50W (inverter loss)
Battery:     P_battery = P_solar - Inverter_DC_in
                       = P_solar - P_house + P_grid - 50
```

- `P_battery > 0` → battery is **charging**
- `P_battery < 0` → battery is **discharging**

---

## Config structure

`configuration.yaml` is a frozen ConfigMap (managed via Git/ArgoCD). It loads:
- `automations.yaml` — HA UI automations (written by HA itself)
- `packages/` — all integration config (YAML files dropped here, no ConfigMap changes needed)

To add new integrations, create files in `/config/packages/` via **code-server** at
`https://haconfig.ruddenchaux.xyz`. HA will pick them up after a config reload
(Developer Tools → All YAML → Check Configuration → Restart).

---

## HA configuration

### Prerequisites

1. Add the MQTT broker once via the UI:
   **Settings → Integrations → MQTT → `192.168.88.237:1883`**

2. All sensor definitions below go in `/config/packages/` files, edited via code-server.

---

### packages/mqtt.yaml

Create at `/config/packages/mqtt.yaml` via code-server.

```yaml
mqtt:
  sensor:
    - name: "House Load Power"
      unique_id: house_load_power
      state_topic: "emon/emonTx4_17/P2"
      unit_of_measurement: "W"
      device_class: power
      state_class: measurement

    - name: "Grid Import Power"
      unique_id: grid_import_power
      state_topic: "emon/emonTx4_17/P3"
      unit_of_measurement: "W"
      device_class: power
      state_class: measurement

    - name: "Solar Power"
      unique_id: solar_power
      state_topic: "emon/system/solar-power"
      unit_of_measurement: "W"
      device_class: power
      state_class: measurement
```

---

### packages/energy.yaml

Create at `/config/packages/energy.yaml` via code-server.
Contains template sensors (battery power derived from solar/grid) and Riemann sum
integrations (W → kWh) for the HA Energy Dashboard.

```yaml
template:
  - sensor:
      - name: "Battery Power"
        unique_id: battery_power
        unit_of_measurement: "W"
        device_class: power
        state_class: measurement
        state: >
          {% set solar = states('sensor.solar_power') | float(0) %}
          {% set house = states('sensor.house_load_power') | float(0) %}
          {% set grid  = states('sensor.grid_import_power') | float(0) %}
          {{ (solar - house + grid - 50) | round(1) }}
        availability: >
          {{ states('sensor.solar_power') not in ['unavailable', 'unknown', 'none']
             and states('sensor.house_load_power') not in ['unavailable', 'unknown', 'none']
             and states('sensor.grid_import_power') not in ['unavailable', 'unknown', 'none'] }}

      - name: "Battery Charging Power"
        unique_id: battery_charging_power
        unit_of_measurement: "W"
        device_class: power
        state_class: measurement
        state: >
          {% set bat = states('sensor.battery_power') | float(0) %}
          {{ [bat, 0] | max | round(1) }}
        availability: "{{ states('sensor.battery_power') not in ['unavailable', 'unknown', 'none'] }}"

      - name: "Battery Discharging Power"
        unique_id: battery_discharging_power
        unit_of_measurement: "W"
        device_class: power
        state_class: measurement
        state: >
          {% set bat = states('sensor.battery_power') | float(0) %}
          {{ ([bat, 0] | min | abs) | round(1) }}
        availability: "{{ states('sensor.battery_power') not in ['unavailable', 'unknown', 'none'] }}"

sensor:
  - platform: integration
    source: sensor.solar_power
    name: "Solar Energy"
    unique_id: solar_energy
    unit_prefix: k
    method: trapezoidal
    round: 3

  - platform: integration
    source: sensor.grid_import_power
    name: "Grid Energy Import"
    unique_id: grid_energy_import
    unit_prefix: k
    method: trapezoidal
    round: 3

  - platform: integration
    source: sensor.battery_charging_power
    name: "Battery Energy Charged"
    unique_id: battery_energy_charged
    unit_prefix: k
    method: trapezoidal
    round: 3

  - platform: integration
    source: sensor.battery_discharging_power
    name: "Battery Energy Discharged"
    unique_id: battery_energy_discharged
    unit_prefix: k
    method: trapezoidal
    round: 3
```

---

### HA Energy Dashboard

**Settings → Dashboards → Energy**, configure:

| Section | Sensor |
|---|---|
| Solar panels | `sensor.solar_energy` |
| Grid consumption | `sensor.grid_energy_import` |
| Energy going into battery | `sensor.battery_energy_charged` |
| Energy coming out of battery | `sensor.battery_energy_discharged` |

---

### Sensor summary

| Sensor | Entity ID | Type |
|---|---|---|
| Solar power | `sensor.solar_power` | MQTT, W |
| House load | `sensor.house_load_power` | MQTT, W |
| Grid import | `sensor.grid_import_power` | MQTT, W |
| Battery power | `sensor.battery_power` | Template, W (+ charge / − discharge) |
| Battery charging power | `sensor.battery_charging_power` | Template, W (≥ 0) |
| Battery discharging power | `sensor.battery_discharging_power` | Template, W (≥ 0) |
| Solar energy | `sensor.solar_energy` | Integration, kWh |
| Grid energy import | `sensor.grid_energy_import` | Integration, kWh |
| Battery energy charged | `sensor.battery_energy_charged` | Integration, kWh |
| Battery energy discharged | `sensor.battery_energy_discharged` | Integration, kWh |

---

## Adding new integrations

`configuration.yaml` is frozen. All new config goes in `/config/packages/` via code-server
at `https://haconfig.ruddenchaux.xyz`. After saving, reload HA:

**Developer Tools → All YAML → Check Configuration → Restart**

Or via the HA REST API:
```bash
curl -X POST http://ha.ruddenchaux.xyz/api/services/homeassistant/reload_all \
  -H "Authorization: Bearer <long-lived-token>"
```
