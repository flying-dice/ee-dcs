# Airbase clearance order changes

The old Lua snapshot predates unrelated deliberate TypeScript changes to CJTF countries, stock FARP shape and hot parking starts (commit `7700054`). Historical Lua snapshots are compared raw to Lua only; current clearance expectations are compared raw to TypeScript without rewriting either side.

The pinned pre-deletion Lua fixtures (`baseline-310.json`, `baseline-2100.json`) remain unchanged. The current TypeScript campaign is recorded separately in `clearance-310.json` and `clearance-2100.json`. Both current fixtures compare every issued order in sequence, including route coordinates, unit composition, task parameters and repeated calls.

| Duration | Baseline ticks | Clearance ticks | Baseline orders | Clearance orders | Moved addGroup orders | Changed setTask orders | Skipped generated statics |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 310 s | 413 | 423 | 171 | 169 | 46 | 2 | 2 |
| 2100 s | 2761 | 2831 | 181 | 179 | 46 | 2 | 2 |

The extra 10 and 70 ticks come from the 30-second runtime clearance sweep. The two omitted installation statics would have occupied the protected airfield envelope. The coordinates below are first-unit world X,Z for groups and object X,Z for statics, in metres. The same order changes occur in both durations.

Relocation follows each rejected candidate bearing from its keysite, preserving defence-ring dispersion. If a runtime intruder lacks a candidate bearing, its bearing is measured from the airfield centre; an exact-centre tie uses a stable group-name bearing.

| Issued order | Baseline X,Z | Clearance X,Z | Reason |
| --- | ---: | ---: | --- |
| GndCol-2-2001 | -29324,10472 | -27474.661,11763.254 | ground column origin moved beyond airfield envelope |
| Arty-2-2002 | -31234.065,11193.855 | -32206.468,12134.573 | artillery origin moved beyond airfield envelope |
| GndCol-2-2007 | -89962,-184 | -89377.059,-3016.346 | ground column origin moved beyond airfield envelope |
| Arty-2-2008 | -91412.654,134.268 | -93056.226,290.485 | artillery origin moved beyond airfield envelope |
| GndCol-1-2013 | 29913,-23 | 26906.285,-817.879 | ground column origin moved beyond airfield envelope |
| Arty-1-2014 | 31631.37,155.763 | 33056.101,291.796 | artillery origin moved beyond airfield envelope |
| GndCol-1-2016 | 90319,9661 | 92172.394,7691.406 | ground column origin moved beyond airfield envelope |
| Arty-1-2017 | 91665.09,10049.969 | 93068.619,10092.088 | artillery origin moved beyond airfield envelope |
| Inst-factory-Red Rear | 92723.233,10126.785 | skipped | generated installation static inside airfield envelope |
| Inst-depot-Blue Rear | -92634.329,316.306 | skipped | generated installation static inside airfield envelope |
| AD-Red Front-2022 | 31500,0 | 32990,0 | air defence origin moved beyond airfield envelope |
| FP-Red Front-2023 | 30533.332,-64.744 | 32908.646,-353.097 | firing point origin moved beyond airfield envelope |
| FP-Red Front-2024 | 29868.204,-446.372 | 29170.298,-2810.07 | firing point origin moved beyond airfield envelope |
| AD-Blue Front-2025 | -28500,10000 | -27010,10000 | air defence origin moved beyond airfield envelope |
| FP-Blue Front-2026 | -29986.309,9971.179 | -28742.786,7353.434 | firing point origin moved beyond airfield envelope |
| FP-Blue Front-2027 | -31190.507,9390.535 | -32608.1,8664.817 | firing point origin moved beyond airfield envelope |
| AD-Red Rear-2031 | 91500,10000 | 92990,10000 | air defence origin moved beyond airfield envelope |
| AD-Red Rear-2032 | 89250,11299.038 | 88505,12589.416 | air defence origin moved beyond airfield envelope |
| AD-Red Rear-2033 | 89250,8700.962 | 88505,7410.584 | air defence origin moved beyond airfield envelope |
| FP-Red Rear-2034 | 89946.838,10011.89 | 87140.644,10639.519 | firing point origin moved beyond airfield envelope |
| FP-Red Rear-2035 | 90779.143,9855.085 | 92880.599,9464.229 | firing point origin moved beyond airfield envelope |
| FP-Red Rear-2036 | 89877.098,10159.407 | 88210.976,12320.408 | firing point origin moved beyond airfield envelope |
| FP-Red Rear-2037 | 89987.118,10472.159 | 89920.089,12928.91 | firing point origin moved beyond airfield envelope |
| AD-Blue Rear-2041 | -88500,0 | -87010,0 | air defence origin moved beyond airfield envelope |
| AD-Blue Rear-2042 | -90750,1299.038 | -91495,2589.416 | air defence origin moved beyond airfield envelope |
| AD-Blue Rear-2043 | -90750,-1299.038 | -91495,-2589.416 | air defence origin moved beyond airfield envelope |
| FP-Blue Rear-2044 | -89702.453,-488.778 | -88476.445,-2502.735 | firing point origin moved beyond airfield envelope |
| FP-Blue Rear-2045 | -89526.248,660.268 | -88291.887,2380.599 | firing point origin moved beyond airfield envelope |
| FP-Blue Rear-2046 | -89054.073,296.687 | -87204.288,876.866 | firing point origin moved beyond airfield envelope |
| FP-Blue Rear-2047 | -91159.164,658.298 | -92547.808,1446.92 | firing point origin moved beyond airfield envelope |
| FP-Inst-factory-2052 | 92668.773,10117.727 | 87143.696,9198.792 | firing point origin moved beyond airfield envelope |
| AD-Inst-radar-B-2057 | -31081.273,11742.043 | -26477.163,11742.043 | air defence origin moved beyond airfield envelope |
| FP-Inst-radar-B-2059 | -31907.061,11733.898 | -26537.604,11669.029 | firing point origin moved beyond airfield envelope |
| AD-Inst-depot-B-2075 | -91134.329,316.306 | -86991.078,316.306 | air defence origin moved beyond airfield envelope |
| FP-Inst-depot-B-2077 | -92332.522,363.207 | -87117.299,1173.668 | firing point origin moved beyond airfield envelope |
| AD-Inst-radar-B-2078 | -92129.288,639.588 | -86954.074,639.588 | air defence origin moved beyond airfield envelope |
| AD-Inst-fuel-Bl-2084 | -91514.37,839.387 | -86895.313,839.387 | air defence origin moved beyond airfield envelope |
| FP-Inst-fuel-Bl-2085 | -91682.068,493.408 | -87149.829,-683.548 | firing point origin moved beyond airfield envelope |
| AD-Inst-depot-B-2087 | -30256.273,12218.357 | -25936.856,12218.357 | air defence origin moved beyond airfield envelope |
| FP-Inst-depot-B-2089 | -30942.361,11029.513 | -28502.683,7465.985 | firing point origin moved beyond airfield envelope |
| AD-Inst-refiner-2093 | -91514.37,-206.775 | -87002.916,-206.775 | air defence origin moved beyond airfield envelope |
| FP-Inst-fuel-Bl-2101 | -31894.873,11849.689 | -28381.116,7524.13 | firing point origin moved beyond airfield envelope |
| AD-Inst-factory-2111 | -92129.288,-6.976 | -87009.993,-6.976 | air defence origin moved beyond airfield envelope |
| FP-Inst-radar-R-2124 | 91381.478,11025.435 | 87061.38,11837.087 | firing point origin moved beyond airfield envelope |
| Patrol-Blue Front-2126 | -30221.751,9764.874 | -32024.032,7853.888 | patrol origin moved beyond airfield envelope |
| Patrol-Blue Rear-2128 | -90230.476,-199.397 | -92230.951,-1930.119 | patrol origin moved beyond airfield envelope |
| Patrol-Red Front-2131 | 29941.063,318.149 | 29462.658,2900.649 | patrol origin moved beyond airfield envelope |
| Patrol-Red Rear-2132 | 89690.406,10053.018 | 87092.328,10497.942 | patrol origin moved beyond airfield envelope |

Two `setTask` orders for artillery groups carry revised first waypoints because their spawn origins moved. Their route type, action, speed and task parameters remain subject to the exact fixture comparison.

| Issued task order | Baseline first waypoint X,Z | Clearance first waypoint X,Z | Reason |
| --- | ---: | ---: | --- |
| setTask Arty-2-2002 | -26769.809,6898.232 | -27255.352,7369.275 | artillery origin moved |
| setTask Arty-2-2008 | -58819.267,-2095.915 | -59641.199,-2018.425 | artillery origin moved |

A negative regression check changed the recorded route X of `FP-Blue Front-2026` by 1 m. The normal test runner failed with `order #59 ... .route[0].x: -28741.786 vs -28742.786`; the fixture was restored immediately afterward.
