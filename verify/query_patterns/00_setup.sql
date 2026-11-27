-- Scratch database for the query-pattern measurements. Synthetic data only; drop it afterwards:
--   DROP DATABASE tune;
CREATE DATABASE IF NOT EXISTS tune;
CREATE TABLE IF NOT EXISTS tune.logs AS gcl.gcl_logs_v1;
