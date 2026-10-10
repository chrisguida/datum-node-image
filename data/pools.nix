# Bitcoin DATUM pools, with their server public keys pinned.
#
# A pinned key is what makes the gateway refuse an impostor: the CONVOY build
# with an empty pool_pubkey accepts whatever key the far end presents. Every
# entry here was copied from the pool's own published connection page on the
# date noted; re-check before a release, keys can rotate.
{
  omegapool = {
    name = "OmegaPool";
    url = "https://pool.iohzrd.tech/miners";
    stats = "https://pool.iohzrd.tech/stats.json";
    # iohzrd's pool (ratum backend). https://pool.iohzrd.tech/connect fills the
    # values from https://pool.iohzrd.tech/stats.json (.pool.datum_port, .pool.pubkey);
    # copied 2026-09-30, pool version 0.1.54, fee 0.5%.
    host = "pool.iohzrd.tech";
    port = 28915;
    pubkey = "e0af9254ca56f93666922eb268c57f3d62f0132eb6f204db0d3124efbe74fc58028496951ea1e68041986c274b66dedb9a8dfa689403757a7868084d4355bb63";
  };

  paperclip = {
    name = "Paperclip";
    url = "https://pool.paperclippool.xyz/#address-dashboard";
    stats = "https://pool.paperclippool.xyz/api/status";
    # https://pool.paperclippool.xyz/ fills the values from /api/status
    # (.stats.pool.datum_port, .stats.pool.pubkey); copied 2026-09-30, 0% DATUM fee.
    host = "pool.paperclippool.xyz";
    port = 28915;
    pubkey = "eb9c7885044ca6dc7a4af3761cb739cbf88e88f6852e6c4b4f754710ec0cc8c9fb4a78cb35bbfe6ac4ec83feb0030e5e8ac065baf87d9ab21489011f3d865478";
  };

  lazarus = {
    # https://pool.lazarus-xbt.xyz/connect; values from https://pool.lazarus-xbt.xyz/api/pool
    # (.datum.pool_pubkey), DATUM host from the connect page; copied 2026-10-02, 0% DATUM fee.
    name = "Lazarus";
    host = "datum.lazarus-xbt.xyz";
    port = 28915;
    pubkey = "29120606bbbfdeb0dcb259d13ed1fba9e6ff198ff6a0152cffb7608dc1c266bd17532393738aee7edf9aa0c9ec93b835256971f186da878f77fb3ed273dff30a";
    url = "https://pool.lazarus-xbt.xyz/miner/{address}";
    stats = "https://pool.lazarus-xbt.xyz/api";
    schema = "lazarus";
  };

  convoy = {
    name = "CONVOY";
    url = "https://convoy.xyz/stats";
    # https://convoy.xyz/getstarted (2026-09-30)
    host = "datum-beta1.mine.convoy.xyz";
    port = 28915;
    pubkey = "dbb11fa0c2b5403e4f798fa6071bb97e6079d219598366032fdf2ae01962b13c5e66e2be7d6b008f0b2603f3e6f6fc64768fa786c8129c46d3e30a5867734b62";
  };

  maveth = {
    name = "RIPTIDE (Maveth)";
    url = "https://riptide.maveth.ca/connect";
    # https://riptide.maveth.ca/connect publishes the gateway config JSON (pool_host, pool_port,
    # pool_pubkey); "soft main" port 29120: 0% fee, min diff 2048, ABW off. Copied 2026-10-10.
    host = "riptide.maveth.ca";
    port = 29120;
    pubkey = "b95abf4a11050c5164d09e9d3c4a18a4df735c5d670e3e974fc146794efa4ed9fbc78e7cd4b6abcd3fcc0e0619543d60004fdb49e9d2974582ae11988a03d743";
  };
}
