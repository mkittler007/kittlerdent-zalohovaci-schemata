# ⚠️ CITLIVÉ — HyperBackup konfigurace

`synobackup.conf` obsahuje **C2 cloud credentials** (`remote_key`, `remote_secret`, `remote_tenant_id`) v plaintextu — přístup k object-storage bucketům, kam jdou zálohy. `synobackup_server.conf` = server strana.

**S touto složkou zacházej jako s heslem:** nesdílet, nedávat do gitu. (Hub „Zalohovací schemata" už tak drží i `.dss` a `.telegram.env`, takže celá složka je citlivá.)

Pro DR: tyto soubory + šifrovací **PEM klíče** (má Martin) umožní na novém NASu re-napojit HyperBackup na C2 a stáhnout data zpět.
