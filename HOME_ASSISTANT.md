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

## Adding new integrations

`configuration.yaml` is frozen. All new config goes in `/config/packages/` via code-server
at `https://haconfig.ruddenchaux.xyz`. After saving, reload HA:

**Developer Tools → All YAML → Check Configuration → Restart**

Or via the HA REST API:
```bash
curl -X POST http://ha.ruddenchaux.xyz/api/services/homeassistant/reload_all \
  -H "Authorization: Bearer <long-lived-token>"
```
