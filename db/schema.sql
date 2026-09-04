-- ============================================================
-- 实体表:每个模型一行,只记录身份,不记录状态
-- ============================================================
CREATE TABLE entities (
    id              INTEGER PRIMARY KEY,
    source          TEXT NOT NULL,          -- huggingface / modelscope / github
    external_id     TEXT NOT NULL,          -- 如 Qwen/Qwen3-32B
    source_url      TEXT NOT NULL,
    first_seen      TEXT NOT NULL,          -- ISO8601 UTC
    UNIQUE(source, external_id)
);

-- ============================================================
-- 观测表:核心资产。只 INSERT,永不 UPDATE / DELETE
-- 每天每个模型一行。字段是"当天观测到的值"
-- ============================================================
CREATE TABLE observations (
    id                  INTEGER PRIMARY KEY,
    entity_id           INTEGER NOT NULL REFERENCES entities(id),
    observed_at         TEXT NOT NULL,      -- ISO8601 UTC,精确到秒
    observed_date       TEXT NOT NULL,      -- YYYY-MM-DD,便于按天查询

    revision            TEXT,               -- 当时的 commit sha
    declared_license    TEXT,               -- 当时 model card 声明的许可证
    has_license_file    INTEGER,            -- 仓库内是否存在 LICENSE 文件
    license_file_path   TEXT,
    downloads           INTEGER,
    likes               INTEGER,
    pipeline_tag        TEXT,
    base_model_ref      TEXT,               -- 声明的上游,原样存字符串
    tags_json           TEXT,               -- 原样存 JSON 数组
    is_gated            INTEGER,            -- 是否需要申请才能访问
    is_private          INTEGER,
    last_modified       TEXT,               -- 上游自己报告的最后修改时间

    raw_sha256          TEXT NOT NULL,      -- 该条原始响应的 hash
    archive_path        TEXT NOT NULL       -- 原始响应所在的归档文件
);

CREATE INDEX idx_obs_entity_date ON observations(entity_id, observed_date);
CREATE INDEX idx_obs_date        ON observations(observed_date);

-- ============================================================
-- 变更表:由 diff.py 从 observations 计算得出,可随时重算
-- ============================================================
CREATE TABLE changes (
    id              INTEGER PRIMARY KEY,
    entity_id       INTEGER NOT NULL REFERENCES entities(id),
    detected_date   TEXT NOT NULL,
    field           TEXT NOT NULL,          -- 哪个字段变了
    old_value       TEXT,
    new_value       TEXT,
    prev_obs_id     INTEGER REFERENCES observations(id),
    curr_obs_id     INTEGER REFERENCES observations(id),
    severity        TEXT                    -- high / medium / low,见下
);

CREATE INDEX idx_chg_date  ON changes(detected_date);
CREATE INDEX idx_chg_field ON changes(field, severity);

-- ============================================================
-- 运行日志:铁律 4 的落地
-- ============================================================
CREATE TABLE runs (
    id              INTEGER PRIMARY KEY,
    source          TEXT NOT NULL,
    started_at      TEXT NOT NULL,
    finished_at     TEXT,
    status          TEXT NOT NULL,          -- running / success / partial / failed
    attempted       INTEGER DEFAULT 0,
    succeeded       INTEGER DEFAULT 0,
    failed          INTEGER DEFAULT 0,
    archive_path    TEXT,
    archive_sha256  TEXT,                   -- 当日归档文件的 hash
    merkle_root     TEXT,                   -- 当日全部记录的 Merkle root
    error_note      TEXT
);

CREATE INDEX idx_runs_date ON runs(started_at);
