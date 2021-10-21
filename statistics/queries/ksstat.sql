# Computes the scaled ksStat for canary vs prod download speed, computed from tcp snapshots.
# Filters on snapshot based duration between 7 and 10.1 seconds
# Filters just one client sample per machine per day (per IP address)
WITH downloads AS (
  SELECT date AS test_date, ID, a, raw.ClientIP,
  COUNT(*) OVER sequence AS clientSample,  # This assigns sample sequence numbers to each sample for a client on a machine.
  raw.Download.ServerMeasurements[OFFSET(0)].TCPInfo as tcp0, 
  raw.Download.ServerMeasurements[ORDINAL(ARRAY_LENGTH(raw.Download.ServerMeasurements))].TCPInfo as tcpN,
  server.Machine AS machine,
  server.Site AS site,
  LEFT(server.Site, 3) AS metro,
  REGEXP_EXTRACT(ID, "(ndt-?.*)-.*") AS NDTVersion,
  TIMESTAMP_DIFF(raw.Download.EndTime, raw.Download.StartTime, MICROSECOND)/1000000 AS duration,
  raw.Download.ServerMeasurements[ORDINAL(ARRAY_LENGTH(raw.Download.ServerMeasurements))].TCPInfo.ElapsedTime/1000000 AS duration2,
  IFNULL(raw.Download.ClientMetadata, raw.Upload.ClientMetadata) AS tmpClientMetaData,
  FROM `measurement-lab.ndt.ndt7`
  WHERE raw.Download IS NOT NULL AND ARRAY_LENGTH(raw.Download.ServerMeasurements) > 1
    AND raw.clientIP NOT IN
      ("45.56.98.222", "35.192.37.249", "35.225.75.192", "23.228.128.99",
      "2600:3c03::f03c:91ff:fe33:819",  "2605:a601:f1ff:fffe::99")
  WINDOW
    sequence AS (PARTITION BY date, server.Site, server.Machine, raw.ClientIP
    ORDER BY FARM_FINGERPRINT(ID) ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
),

# This join is quite expensive - about 3 slot hours for 2 months of data, even if the clientName field is never used.
ist_4 AS (
  SELECT downloads.* EXCEPT(tmpClientMetadata), clientName
  FROM downloads LEFT JOIN (
    SELECT * EXCEPT(tmpClientMetadata, Name, Value), Value AS clientName
    FROM downloads, downloads.tmpClientMetadata
    WHERE Name = "client_name") cn USING (test_date, ID)
  -- Filtering clientSample > 10 generates ksStat > 7 !!
  -- Filtering clientName != "ist" produces very low ksStat, which suggests those clients don't care much about message size. 
  WHERE downloads.duration2 BETWEEN 7 and 10.1 AND downloads.clientSample < 5 AND cn.clientName = "ist"
),

hist AS (
  SELECT test_date AS date,
--  EXP(ROUND(SAFE.LN(a.MeanThroughputMBPS),3)) AS bin,  # About 100K bins when rounding to 4 digits.
  EXP(ROUND(SAFE.LN(8*SAFE_DIVIDE(tcpN.BytesAcked-tcp0.bytesAcked,tcpN.ElapsedTime-tcp0.ElapsedTime)),3)) AS bin,
  EXP(AVG(IF(NDTVersion = "ndt-canary", SAFE.LN(tcpN.MinRTT), NULL))) AS MeanMinRTT,
  COUNTIF(NDTVersion = "ndt-canary") AS canary,
  COUNTIF(NDTVersion != "ndt-canary") AS prod,
  FROM ist_4
  GROUP BY date, bin
  HAVING bin IS NOT NULL
),

# This uses an OVER clause instead of GROUP BY
cdf AS (
  SELECT *,
  COUNT(bin) OVER byDate AS bins,
  SUM(canary) OVER byDate AS canaryCount, MAX(canary) OVER byDate AS canaryMax, 
  SUM(prod) OVER byDate AS prodCount, 
  EXP(SUM(LN(bin)*canary) OVER byDate/SUM(canary) OVER byDate) AS canaryMeanSpeed,
  EXP(SUM(LN(bin)*prod) OVER byDate/SUM(prod)  OVER byDate) AS prodMeanSpeed,
  SUM(canary) OVER partialSum/SUM(canary) OVER byDate AS canaryCDF,
  SUM(prod) OVER partialSum/SUM(prod) OVER byDate AS prodCDF
  FROM hist
  WINDOW 
    byDate AS (PARTITION BY date),
    partialSum AS (PARTITION BY date ORDER BY bin ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
),

stats AS (
  SELECT  date, COUNT(bin) AS bins,
  canaryCount, prodCount, ROUND(canaryCount/prodCount, 4) AS ratio, 
  canaryMax, prodMeanSpeed, canaryMeanSpeed, canaryMeanSpeed/prodMeanSpeed - 1 AS faster,
  # If this is greater than 1.36, then rejected with alpha = .05
  MAX(ABS(canaryCDF - prodCDF))*SQRT(canaryCount*prodCount)/(SQRT(canaryCount)+SQRT(prodCount)) AS ksStat,
  FROM cdf
  GROUP BY date, canaryCount, canaryMax, prodCount, prodMeanSpeed, canaryMeanSpeed ORDER BY date 
)

SELECT * EXCEPT(faster) FROM stats WHERE date >= "2021-07-15" ORDER BY date




