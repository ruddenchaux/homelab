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

## Manual HA configuration

### Prerequisites

1. Add the MQTT broker once via the UI:
   **Settings → Integrations → MQTT → `192.168.88.237:1883`**

2. All sensor definitions below go in `configuration.yaml` (or separate included files).

---

### mqtt.yaml

Paste under `mqtt:` in `configuration.yaml`, or in a separate `mqtt.yaml` included via `mqtt: !include mqtt.yaml`.

```yaml
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

### template.yaml

Paste under `template:` in `configuration.yaml`, or in a separate `template.yaml` included via `template: !include template.yaml`.

```yaml
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
```

---

### sensor.yaml

Paste under `sensor:` in `configuration.yaml`, or in a separate `sensor.yaml` included via `sensor: !include sensor.yaml`.

These are Riemann sum integrations (W → kWh) for the HA Energy Dashboard.

```yaml
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

## GitOps integration (when ready)

When the manual config is validated, the same YAML is applied via the k8s ConfigMap in
`kubernetes/platform/home-assistant/templates/configmap.yaml`.

Add to `configuration.yaml` in the ConfigMap:
```yaml
mqtt: !include mqtt.yaml
template: !include template.yaml
sensor: !include sensor.yaml
```

Add three new ConfigMap keys (`mqtt.yaml`, `template.yaml`, `sensor.yaml`) with the content above.

Mount each in `deployment.yaml` alongside the existing `configuration.yaml` subPath mount:
```yaml
- name: ha-configuration
  mountPath: /config/mqtt.yaml
  subPath: mqtt.yaml
- name: ha-configuration
  mountPath: /config/template.yaml
  subPath: template.yaml
- name: ha-configuration
  mountPath: /config/sensor.yaml
  subPath: sensor.yaml
```

Trigger a rollout after ArgoCD syncs:
```bash
ssh debian@10.30.0.10 'kubectl rollout restart deployment/home-assistant -n home-assistant'
```
