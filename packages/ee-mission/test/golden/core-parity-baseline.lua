-- GOLDEN FIXTURE - recorded answers of the LUA CAMPAIGN BASELINE (Scripts/ee-dcs/*.lua)
-- for every core-parity `check`, captured at the pre-deletion state of that tree on 2026-09-21.
-- core-parity.lua asserts the typescript build against these values once the lua tree is
-- gone. Do not hand-edit: regenerate with
--   lua packages/ee-mission/test/core-parity.lua <repo-root> --emit-golden
-- and only when a change to the BASELINE behaviour is intended.
return {
  ["config defaults"] = { value = {
    ["countries"] = {
      [1] = 81,
      [2] = 80
    },
    ["defenses"] = {
      ["firing_points"] = {
        ["airbase"] = 4,
        ["farp"] = 2,
        ["installation"] = 2
      },
      ["group"] = {
        [1] = {
          [1] = "2S6 Tunguska",
          [2] = "Strela-10M3"
        },
        [2] = {
          [1] = "M48 Chaparral",
          [2] = "Vulcan"
        }
      },
      ["groups_per"] = {
        ["airbase"] = 3,
        ["farp"] = 1,
        ["installation"] = 1
      },
      ["manpad"] = {
        [1] = "SA-18 Igla manpad",
        [2] = "Soldier stinger"
      },
      ["mg"] = {
        [1] = "Infantry AK",
        [2] = "Soldier M4"
      },
      ["ring_radius"] = 1500
    },
    ["mode"] = "campaign",
    ["payloads"] = {
      [1] = {
        ["attack_heli"] = {
          [1] = {
            ["CLSID"] = "{B919B0F4-7C25-455E-9A02-CEA51DB895E3}",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}",
            ["num"] = 4
          },
          [5] = {
            ["CLSID"] = "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}",
            ["num"] = 5
          },
          [6] = {
            ["CLSID"] = "{B919B0F4-7C25-455E-9A02-CEA51DB895E3}",
            ["num"] = 6
          }
        },
        ["escort"] = {
          [1] = {
            ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{B79C379A-9E87-4E50-A1EE-7F7E29C2E87A}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}",
            ["num"] = 4
          },
          [5] = {
            ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}",
            ["num"] = 5
          },
          [6] = {
            ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}",
            ["num"] = 6
          },
          [7] = {
            ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}",
            ["num"] = 7
          },
          [8] = {
            ["CLSID"] = "{B79C379A-9E87-4E50-A1EE-7F7E29C2E87A}",
            ["num"] = 8
          },
          [9] = {
            ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 9
          },
          [10] = {
            ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 10
          }
        },
        ["striker"] = {
          [1] = {
            ["CLSID"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82D}",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{CBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{E8D4652F-FD48-45B7-BA5B-2AE05BB5A9CF}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "{601C99F7-9AF3-4ed7-A565-F8B8EC0D7AAC}",
            ["num"] = 5
          },
          [5] = {
            ["CLSID"] = "{601C99F7-9AF3-4ed7-A565-F8B8EC0D7AAC}",
            ["num"] = 7
          },
          [6] = {
            ["CLSID"] = "{E8D4652F-FD48-45B7-BA5B-2AE05BB5A9CF}",
            ["num"] = 9
          },
          [7] = {
            ["CLSID"] = "{CBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 10
          },
          [8] = {
            ["CLSID"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82C}",
            ["num"] = 11
          }
        }
      },
      [2] = {
        ["attack_heli"] = {
          [1] = {
            ["CLSID"] = "M261_MK151",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{88D18A5E-99C8-4B04-B40B-1C02F2018B6E}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{88D18A5E-99C8-4B04-B40B-1C02F2018B6E}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "M261_MK151",
            ["num"] = 4
          },
          [5] = {
            ["CLSID"] = "{IAFS_ComboPak_100}",
            ["num"] = 5
          },
          [6] = {
            ["CLSID"] = "{AN_APG_78}",
            ["num"] = 6
          }
        },
        ["escort"] = {
          [1] = {
            ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{E1F29B21-F291-4589-9FD8-3272EEC69506}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "{C8E06185-7CD6-4C90-959F-044679E90751}",
            ["num"] = 4
          },
          [5] = {
            ["CLSID"] = "{C8E06185-7CD6-4C90-959F-044679E90751}",
            ["num"] = 5
          },
          [6] = {
            ["CLSID"] = "{E1F29B21-F291-4589-9FD8-3272EEC69506}",
            ["num"] = 6
          },
          [7] = {
            ["CLSID"] = "{C8E06185-7CD6-4C90-959F-044679E90751}",
            ["num"] = 7
          },
          [8] = {
            ["CLSID"] = "{C8E06185-7CD6-4C90-959F-044679E90751}",
            ["num"] = 8
          },
          [9] = {
            ["CLSID"] = "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}",
            ["num"] = 9
          },
          [10] = {
            ["CLSID"] = "{E1F29B21-F291-4589-9FD8-3272EEC69506}",
            ["num"] = 10
          },
          [11] = {
            ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}",
            ["num"] = 11
          }
        },
        ["striker"] = {
          [1] = {
            ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{5CE2FF2A-645A-4197-B48D-8720AC69394F}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{DB769D48-67D7-42ED-A2BE-108D566C8B1E}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "{F376DBEE-4CAE-41BA-ADD9-B2910AC95DEC}",
            ["num"] = 4
          },
          [5] = {
            ["CLSID"] = "{A111396E-D3E8-4b9c-8AC9-2432489304D5}",
            ["num"] = 5
          },
          [6] = {
            ["CLSID"] = "{F376DBEE-4CAE-41BA-ADD9-B2910AC95DEC}",
            ["num"] = 6
          },
          [7] = {
            ["CLSID"] = "{DB769D48-67D7-42ED-A2BE-108D566C8B1E}",
            ["num"] = 7
          },
          [8] = {
            ["CLSID"] = "{5CE2FF2A-645A-4197-B48D-8720AC69394F}",
            ["num"] = 8
          },
          [9] = {
            ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}",
            ["num"] = 9
          }
        }
      }
    },
    ["persistence"] = {
      ["autosave_period"] = 300,
      ["db_path"] = "dmt_campaign.sqlite",
      ["enabled"] = false,
      ["slot"] = "default"
    },
    ["reserves"] = {
      ["farp_heli"] = 4,
      ["farp_transport"] = 2,
      ["per_base"] = {
        ["escort"] = 2,
        ["heli"] = 6,
        ["recon"] = 1,
        ["striker"] = 4,
        ["transport"] = 3,
        ["vehicle"] = 2
      }
    },
    ["statics"] = {
      ["farp"] = {
        ["category"] = "Heliports",
        ["shape_name"] = "<verified four-slot FARP shape>",
        ["type"] = "FARP"
      },
      ["kinds"] = {
        ["command"] = {
          ["cat"] = "Fortifications",
          ["label"] = "Command Post",
          ["shape"] = "ComCenter",
          ["spawn"] = "static",
          ["type"] = ".Command Center"
        },
        ["depot"] = {
          ["cat"] = "Cargos",
          ["label"] = "Supply Depot",
          ["shape"] = "M92_Container_10ft",
          ["spawn"] = "static",
          ["type"] = "M92_10Ft_Container"
        },
        ["factory"] = {
          ["cat"] = "Fortifications",
          ["label"] = "Munitions Factory",
          ["shape"] = "kotelnaya_a",
          ["spawn"] = "static",
          ["type"] = "Boiler-house A"
        },
        ["fuel"] = {
          ["cat"] = "Fortifications",
          ["label"] = "Fuel Depot",
          ["shape"] = "GSM Rus",
          ["spawn"] = "static",
          ["type"] = "FARP Fuel Depot"
        },
        ["radar"] = {
          ["label"] = "Radar/EWR",
          ["spawn"] = "unit",
          ["unit"] = {
            [1] = "55G6 EWR",
            [2] = "Hawk sr"
          }
        },
        ["refinery"] = {
          ["cat"] = "Fortifications",
          ["label"] = "Oil Refinery",
          ["shape"] = "GSM Rus",
          ["spawn"] = "static",
          ["type"] = "FARP Fuel Depot"
        }
      },
      ["palette"] = {
        ["ammo"] = {
          [1] = ".Ammunition depot",
          [2] = "SkladC",
          [3] = "Warehouses"
        },
        ["bunker"] = {
          [1] = "FARP CP Blindage",
          [2] = "kp_ug",
          [3] = "Fortifications"
        },
        ["command"] = {
          [1] = ".Command Center",
          [2] = "ComCenter",
          [3] = "Fortifications"
        },
        ["container"] = {
          [1] = "M92_10Ft_Container",
          [2] = "M92_Container_10ft",
          [3] = "Cargos"
        },
        ["factory"] = {
          [1] = "Boiler-house A",
          [2] = "kotelnaya_a",
          [3] = "Fortifications"
        },
        ["fuel"] = {
          [1] = "FARP Fuel Depot",
          [2] = "GSM Rus",
          [3] = "Fortifications"
        },
        ["fueltank"] = {
          [1] = "Tank",
          [2] = "bak",
          [3] = "Warehouses"
        },
        ["warehouse"] = {
          [1] = "Warehouse",
          [2] = "sklad",
          [3] = "Warehouses"
        }
      }
    },
    ["theatre"] = {
      ["farp_activation"] = true,
      ["farp_front_dist"] = 260000,
      ["fixed_wing_per_side"] = 2,
      ["front_dist"] = 140000
    },
    ["types"] = {
      ["aircraft"] = {
        [1] = {
          ["attack_heli"] = "Mi-24V",
          ["bda_heli"] = "Mi-8MT",
          ["escort"] = "Su-27",
          ["recon"] = "Su-27",
          ["striker"] = "Su-25T",
          ["transport_fw"] = "An-26B",
          ["transport_fw_heavy"] = "IL-76MD",
          ["transport_heli"] = "Mi-8MT"
        },
        [2] = {
          ["attack_heli"] = "AH-64D",
          ["bda_heli"] = "UH-60A",
          ["escort"] = "F-15C",
          ["recon"] = "F-15C",
          ["striker"] = "F-16C bl.52d",
          ["transport_fw"] = "C-130",
          ["transport_fw_heavy"] = "C-17A",
          ["transport_heli"] = "UH-60A"
        }
      },
      ["ground"] = {
        ["aaa"] = {
          [1] = "ZSU-23-4 Shilka",
          [2] = "Vulcan"
        },
        ["arty_slots"] = {
          [1] = {
            [1] = "M-109",
            [2] = "SAU Msta"
          },
          [2] = {
            [1] = "M-109",
            [2] = "SAU Msta"
          },
          [3] = {
            [1] = "M 818",
            [2] = "Ural-375"
          },
          [4] = {
            [1] = "M1043 HMMWV Armament",
            [2] = "UAZ-469"
          }
        },
        ["ewr"] = {
          [1] = "55G6 EWR",
          [2] = "Hawk sr"
        },
        ["garrison"] = {
          [1] = {
            [1] = "T-80UD",
            [2] = "BMP-2",
            [3] = "BMP-2",
            [4] = "BTR-80"
          },
          [2] = {
            [1] = "M-1 Abrams",
            [2] = "M2A2 Bradley",
            [3] = "M2A2 Bradley",
            [4] = "M1043 HMMWV Armament"
          }
        },
        ["infantry"] = {
          [1] = "Infantry AK",
          [2] = "Soldier M4"
        },
        ["mlrs_slots"] = {
          [1] = {
            [1] = "MLRS",
            [2] = "Grad-URAL"
          },
          [2] = {
            [1] = "MLRS",
            [2] = "Grad-URAL"
          },
          [3] = {
            [1] = "M 818",
            [2] = "Ural-375"
          },
          [4] = {
            [1] = "M1043 HMMWV Armament",
            [2] = "UAZ-469"
          }
        },
        ["primary_slots"] = {
          [1] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [2] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [3] = {
            [1] = "M2A2 Bradley",
            [2] = "BMP-2"
          },
          [4] = {
            [1] = "M1097 Avenger",
            [2] = "2S6 Tunguska"
          },
          [5] = {
            [1] = "M2A2 Bradley",
            [2] = "BMP-3"
          },
          [6] = {
            [1] = "M48 Chaparral",
            [2] = "Strela-10M3"
          },
          [7] = {
            [1] = "M-113",
            [2] = "BTR-80"
          },
          [8] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [9] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [10] = {
            [1] = "M2A2 Bradley",
            [2] = "BMP-2"
          },
          [11] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [12] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [13] = {
            [1] = "M-113",
            [2] = "BTR-80"
          },
          [14] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [15] = {
            [1] = "M-113",
            [2] = "BTR-80"
          },
          [16] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          }
        },
        ["sam"] = {
          [1] = {
            [1] = "Kub 1S91 str",
            [2] = "Kub 2P25 ln"
          },
          [2] = {
            [1] = "Roland ADS"
          }
        },
        ["secondary_slots"] = {
          [1] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [2] = {
            [1] = "M48 Chaparral",
            [2] = "Strela-10M3"
          },
          [3] = {
            [1] = "M2A2 Bradley",
            [2] = "BMP-3"
          },
          [4] = {
            [1] = "M 818",
            [2] = "Ural-375"
          },
          [5] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [6] = {
            [1] = "M978 HEMTT Tanker",
            [2] = "ATZ-10"
          },
          [7] = {
            [1] = "M1043 HMMWV Armament",
            [2] = "BRDM-2"
          },
          [8] = {
            [1] = "M-113",
            [2] = "BTR-80"
          },
          [9] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [10] = {
            [1] = "M 818",
            [2] = "Ural-375"
          },
          [11] = {
            [1] = "M-113",
            [2] = "BTR-80"
          },
          [12] = {
            [1] = "M48 Chaparral",
            [2] = "Strela-10M3"
          },
          [13] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [14] = {
            [1] = "M978 HEMTT Tanker",
            [2] = "ATZ-10"
          },
          [15] = {
            [1] = "M48 Chaparral",
            [2] = "Strela-10M3"
          },
          [16] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          }
        }
      }
    }
  } },
  ["config CJTF countries"] = { value = true },
  ["config pylon without num"] = { value = {
    [1] = {
      ["CLSID"] = "custom"
    }
  } },
  ["config extra palette token"] = { value = {
    ["ammo"] = {
      [1] = ".Ammunition depot",
      [2] = "SkladC",
      [3] = "Warehouses"
    },
    ["bunker"] = {
      [1] = "FARP CP Blindage",
      [2] = "kp_ug",
      [3] = "Fortifications"
    },
    ["command"] = {
      [1] = ".Command Center",
      [2] = "ComCenter",
      [3] = "Fortifications"
    },
    ["container"] = {
      [1] = "M92_10Ft_Container",
      [2] = "M92_Container_10ft",
      [3] = "Cargos"
    },
    ["custom"] = {
      [1] = "Custom",
      [2] = "shape",
      [3] = "Fortifications"
    },
    ["factory"] = {
      [1] = "Boiler-house A",
      [2] = "kotelnaya_a",
      [3] = "Fortifications"
    },
    ["fuel"] = {
      [1] = "FARP Fuel Depot",
      [2] = "GSM Rus",
      [3] = "Fortifications"
    },
    ["fueltank"] = {
      [1] = "Tank",
      [2] = "bak",
      [3] = "Warehouses"
    },
    ["warehouse"] = {
      [1] = "Warehouse",
      [2] = "sklad",
      [3] = "Warehouses"
    }
  } },
  ["config custom static kind"] = { value = {
    ["bridge"] = {
      ["cat"] = "Fortifications",
      ["label"] = "Bridge",
      ["shape"] = "bridge",
      ["spawn"] = "static",
      ["type"] = "Custom"
    },
    ["command"] = {
      ["cat"] = "Fortifications",
      ["label"] = "Command Post",
      ["shape"] = "ComCenter",
      ["spawn"] = "static",
      ["type"] = ".Command Center"
    },
    ["depot"] = {
      ["cat"] = "Cargos",
      ["label"] = "Supply Depot",
      ["shape"] = "M92_Container_10ft",
      ["spawn"] = "static",
      ["type"] = "M92_10Ft_Container"
    },
    ["factory"] = {
      ["cat"] = "Fortifications",
      ["label"] = "Munitions Factory",
      ["shape"] = "kotelnaya_a",
      ["spawn"] = "static",
      ["type"] = "Boiler-house A"
    },
    ["fuel"] = {
      ["cat"] = "Fortifications",
      ["label"] = "Fuel Depot",
      ["shape"] = "GSM Rus",
      ["spawn"] = "static",
      ["type"] = "FARP Fuel Depot"
    },
    ["radar"] = {
      ["label"] = "Radar/EWR",
      ["spawn"] = "unit",
      ["unit"] = {
        [1] = "55G6 EWR",
        [2] = "Hawk sr"
      }
    },
    ["refinery"] = {
      ["cat"] = "Fortifications",
      ["label"] = "Oil Refinery",
      ["shape"] = "GSM Rus",
      ["spawn"] = "static",
      ["type"] = "FARP Fuel Depot"
    }
  } },
  ["config invalid unit fallback"] = { value = {
    [1] = {
      ["attack_heli"] = "Mi-24V",
      ["bda_heli"] = "Mi-8MT",
      ["escort"] = "Su-27",
      ["recon"] = "Su-27",
      ["striker"] = "Su-25T",
      ["transport_fw"] = "An-26B",
      ["transport_fw_heavy"] = "IL-76MD",
      ["transport_heli"] = "Mi-8MT"
    },
    [2] = {
      ["attack_heli"] = "AH-64D",
      ["bda_heli"] = "UH-60A",
      ["escort"] = "F-15C",
      ["recon"] = "F-15C",
      ["striker"] = "F-16C bl.52d",
      ["transport_fw"] = "C-130",
      ["transport_fw_heavy"] = "C-17A",
      ["transport_heli"] = "UH-60A"
    }
  } },
  ["neutral kill side"] = { value = {
    [1] = {
      ["kills"] = {},
      ["losses"] = {},
      ["sorties"] = 0,
      ["tasks_completed"] = 0,
      ["tasks_created"] = 0,
      ["tasks_failed"] = 0,
      ["tasks_partial"] = 0
    },
    [2] = {
      ["kills"] = {
        ["ground"] = 1
      },
      ["losses"] = {},
      ["sorties"] = 0,
      ["tasks_completed"] = 0,
      ["tasks_created"] = 0,
      ["tasks_failed"] = 0,
      ["tasks_partial"] = 0
    }
  } },
  ["static category after failed descriptor"] = { value = "structure" },
  ["task assessment boundaries"] = { value = {
    [1] = {
      [1] = "success",
      [2] = 1
    },
    [2] = {
      [1] = "success",
      [2] = 1
    },
    [3] = {
      [1] = "success",
      [2] = 0.76000000000000001
    },
    [4] = {
      [1] = "success",
      [2] = 0.25
    },
    [5] = {
      [1] = "failure",
      [2] = 0.099999999999999978
    },
    [6] = {
      [1] = "failure",
      [2] = 0
    }
  } },
  ["strength empty"] = { value = {
    [1] = 50,
    [2] = 50
  } },
  ["route terrain and side bias"] = { value = {
    [1] = {
      ["x"] = 601.85185185185117,
      ["z"] = 6656.3786008230463
    },
    [2] = {
      ["x"] = 37680.885112168115,
      ["z"] = 13123.763661423629
    },
    [3] = {
      ["x"] = 40000,
      ["z"] = 15000.000000000005
    },
    [4] = {
      ["x"] = 42451.171875,
      ["z"] = 13245.849609375009
    },
    [5] = {
      ["x"] = 60210.578901072338,
      ["z"] = 14824.828932889628
    },
    [6] = {
      ["x"] = 62225.710139480514,
      ["z"] = 17282.486829078854
    },
    [7] = {
      ["x"] = 63345.522311621913,
      ["z"] = 23613.097980192881
    },
    [8] = {
      ["x"] = 77126.530124685829,
      ["z"] = 32003.834733137381
    }
  } },
  ["imap scheduled layers"] = { value = {
    ["nrm"] = {
      ["AIR_DEFENCE"] = {
        [1] = {},
        [2] = {}
      },
      ["BASE_DISTANCE"] = {
        [1] = {
          ["a"] = 0,
          ["b"] = 1
        },
        [2] = {
          ["a"] = 1,
          ["b"] = 0
        }
      },
      ["IMPORTANCE"] = {
        [1] = {
          ["a"] = 0,
          ["b"] = 1
        },
        [2] = {
          ["a"] = 1,
          ["b"] = 0
        }
      },
      ["SURFACE_DEFENCE"] = {
        [1] = {},
        [2] = {}
      }
    },
    ["raw"] = {
      ["AIR_DEFENCE"] = {
        [1] = {
          ["a"] = 0,
          ["b"] = 0
        },
        [2] = {
          ["a"] = 0,
          ["b"] = 0
        }
      },
      ["BASE_DISTANCE"] = {
        [1] = {
          ["a"] = 0.76444444444444448,
          ["b"] = 1
        },
        [2] = {
          ["a"] = 1,
          ["b"] = 0.76444444444444448
        }
      },
      ["IMPORTANCE"] = {
        [1] = {
          ["a"] = 0.46999999999999997,
          ["b"] = 1
        },
        [2] = {
          ["a"] = 1,
          ["b"] = 0.46999999999999997
        }
      },
      ["SURFACE_DEFENCE"] = {
        [1] = {
          ["a"] = 0,
          ["b"] = 0
        },
        [2] = {
          ["a"] = 0,
          ["b"] = 0
        }
      }
    }
  } },
  ["fow decay and ownership"] = { value = {
    [1] = 1,
    [2] = 0.0048611111111111112
  } },
  ["zones authored circle and quad"] = { value = {
    [1] = 3,
    [2] = {
      [1] = {
        ["label"] = "Depot Quad",
        ["side"] = 1,
        ["type"] = "depot",
        ["x"] = 10,
        ["z"] = 20
      },
      [2] = {
        ["label"] = "Factory Circle",
        ["side"] = 2,
        ["type"] = "factory",
        ["x"] = 100,
        ["z"] = 200
      }
    },
    [3] = true,
    [4] = true,
    [5] = true,
    [6] = false,
    [7] = true,
    [8] = false
  } },
  ["zones bare and wrapped colors"] = { value = {
    [1] = {
      [1] = 2,
      [2] = 2
    },
    [2] = {
      [1] = 1,
      [2] = 1
    },
    [3] = {},
    [4] = {
      [1] = 2,
      [2] = 2
    },
    [5] = {}
  } },
  ["frontline capture and missing bases"] = { value = {
    [1] = {
      [1] = {
        [1] = "b"
      },
      [2] = {
        [1] = "c"
      },
      [3] = {
        ["distance"] = 250,
        ["name"] = "c"
      },
      [5] = "second",
      [6] = "frontline",
      [7] = "second"
    },
    [2] = {
      [1] = "c"
    },
    [3] = {
      [1] = "d"
    },
    [4] = {
      ["distance"] = 150,
      ["name"] = "d"
    }
  } },
  ["route unavailable terrain and short leg"] = { value = {
    [1] = {},
    [2] = {
      [1] = {
        ["x"] = 77291.071487414505,
        ["z"] = 30337.93409596584
      }
    },
    [3] = {
      [1] = {
        ["x"] = 0,
        ["y"] = 0
      },
      [2] = {
        ["ETA"] = 0,
        ["ETA_locked"] = false,
        ["action"] = "Turning Point",
        ["alt"] = 3000,
        ["alt_type"] = "BARO",
        ["formation_template"] = "",
        ["name"] = "Nav1",
        ["speed"] = 200,
        ["type"] = "Turning Point",
        ["x"] = 77291.071487414505,
        ["y"] = 30337.93409596584
      },
      [3] = {
        ["x"] = 80000,
        ["y"] = 30000
      }
    }
  } },
  ["pilot friendly kill and score promotion"] = { value = {
    ["air_medal_counter"] = 0,
    ["deaths"] = 0,
    ["first_seen"] = 0,
    ["kills"] = {
      ["air"] = 75,
      ["air_defence"] = 0,
      ["armour"] = 0,
      ["artillery"] = 0,
      ["fixed"] = 0,
      ["fixed_wing"] = 75,
      ["friendly"] = 1,
      ["ground"] = 0,
      ["helicopter"] = 0,
      ["sea"] = 0,
      ["total"] = 75
    },
    ["medals"] = {
      ["Distinguished Service"] = 1,
      ["Flying Cross"] = 1,
      ["Medal of Honour"] = 1,
      ["Silver Star"] = 1
    },
    ["missions_flown"] = 0,
    ["name"] = "Pilot",
    ["rank"] = 2,
    ["score"] = 7500,
    ["side"] = 2,
    ["sortie_damaged"] = false,
    ["sortie_score_start"] = 0,
    ["sorties"] = 0
  } },
  ["pilot debrief medals and partial streak"] = { value = {
    ["air_medal_counter"] = 0,
    ["deaths"] = 0,
    ["first_seen"] = 0,
    ["kills"] = {
      ["air"] = 0,
      ["air_defence"] = 0,
      ["armour"] = 0,
      ["artillery"] = 0,
      ["fixed"] = 0,
      ["fixed_wing"] = 0,
      ["friendly"] = 0,
      ["ground"] = 0,
      ["helicopter"] = 0,
      ["sea"] = 0,
      ["total"] = 0
    },
    ["medals"] = {
      ["Air Medal"] = 1,
      ["Purple Heart"] = 1
    },
    ["missions_flown"] = 5,
    ["name"] = "Pilot",
    ["rank"] = 1,
    ["score"] = 0,
    ["side"] = 2,
    ["sortie_damaged"] = false,
    ["sortie_score_start"] = 0,
    ["sorties"] = 0
  } },
  ["config non-table override 1"] = { value = {
    ["countries"] = {
      [1] = 81,
      [2] = 80
    },
    ["defenses"] = {
      ["firing_points"] = {
        ["airbase"] = 4,
        ["farp"] = 2,
        ["installation"] = 2
      },
      ["group"] = {
        [1] = {
          [1] = "2S6 Tunguska",
          [2] = "Strela-10M3"
        },
        [2] = {
          [1] = "M48 Chaparral",
          [2] = "Vulcan"
        }
      },
      ["groups_per"] = {
        ["airbase"] = 3,
        ["farp"] = 1,
        ["installation"] = 1
      },
      ["manpad"] = {
        [1] = "SA-18 Igla manpad",
        [2] = "Soldier stinger"
      },
      ["mg"] = {
        [1] = "Infantry AK",
        [2] = "Soldier M4"
      },
      ["ring_radius"] = 1500
    },
    ["mode"] = "campaign",
    ["payloads"] = {
      [1] = {
        ["attack_heli"] = {
          [1] = {
            ["CLSID"] = "{B919B0F4-7C25-455E-9A02-CEA51DB895E3}",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}",
            ["num"] = 4
          },
          [5] = {
            ["CLSID"] = "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}",
            ["num"] = 5
          },
          [6] = {
            ["CLSID"] = "{B919B0F4-7C25-455E-9A02-CEA51DB895E3}",
            ["num"] = 6
          }
        },
        ["escort"] = {
          [1] = {
            ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{B79C379A-9E87-4E50-A1EE-7F7E29C2E87A}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}",
            ["num"] = 4
          },
          [5] = {
            ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}",
            ["num"] = 5
          },
          [6] = {
            ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}",
            ["num"] = 6
          },
          [7] = {
            ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}",
            ["num"] = 7
          },
          [8] = {
            ["CLSID"] = "{B79C379A-9E87-4E50-A1EE-7F7E29C2E87A}",
            ["num"] = 8
          },
          [9] = {
            ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 9
          },
          [10] = {
            ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 10
          }
        },
        ["striker"] = {
          [1] = {
            ["CLSID"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82D}",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{CBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{E8D4652F-FD48-45B7-BA5B-2AE05BB5A9CF}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "{601C99F7-9AF3-4ed7-A565-F8B8EC0D7AAC}",
            ["num"] = 5
          },
          [5] = {
            ["CLSID"] = "{601C99F7-9AF3-4ed7-A565-F8B8EC0D7AAC}",
            ["num"] = 7
          },
          [6] = {
            ["CLSID"] = "{E8D4652F-FD48-45B7-BA5B-2AE05BB5A9CF}",
            ["num"] = 9
          },
          [7] = {
            ["CLSID"] = "{CBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 10
          },
          [8] = {
            ["CLSID"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82C}",
            ["num"] = 11
          }
        }
      },
      [2] = {
        ["attack_heli"] = {
          [1] = {
            ["CLSID"] = "M261_MK151",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{88D18A5E-99C8-4B04-B40B-1C02F2018B6E}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{88D18A5E-99C8-4B04-B40B-1C02F2018B6E}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "M261_MK151",
            ["num"] = 4
          },
          [5] = {
            ["CLSID"] = "{IAFS_ComboPak_100}",
            ["num"] = 5
          },
          [6] = {
            ["CLSID"] = "{AN_APG_78}",
            ["num"] = 6
          }
        },
        ["escort"] = {
          [1] = {
            ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{E1F29B21-F291-4589-9FD8-3272EEC69506}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "{C8E06185-7CD6-4C90-959F-044679E90751}",
            ["num"] = 4
          },
          [5] = {
            ["CLSID"] = "{C8E06185-7CD6-4C90-959F-044679E90751}",
            ["num"] = 5
          },
          [6] = {
            ["CLSID"] = "{E1F29B21-F291-4589-9FD8-3272EEC69506}",
            ["num"] = 6
          },
          [7] = {
            ["CLSID"] = "{C8E06185-7CD6-4C90-959F-044679E90751}",
            ["num"] = 7
          },
          [8] = {
            ["CLSID"] = "{C8E06185-7CD6-4C90-959F-044679E90751}",
            ["num"] = 8
          },
          [9] = {
            ["CLSID"] = "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}",
            ["num"] = 9
          },
          [10] = {
            ["CLSID"] = "{E1F29B21-F291-4589-9FD8-3272EEC69506}",
            ["num"] = 10
          },
          [11] = {
            ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}",
            ["num"] = 11
          }
        },
        ["striker"] = {
          [1] = {
            ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{5CE2FF2A-645A-4197-B48D-8720AC69394F}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{DB769D48-67D7-42ED-A2BE-108D566C8B1E}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "{F376DBEE-4CAE-41BA-ADD9-B2910AC95DEC}",
            ["num"] = 4
          },
          [5] = {
            ["CLSID"] = "{A111396E-D3E8-4b9c-8AC9-2432489304D5}",
            ["num"] = 5
          },
          [6] = {
            ["CLSID"] = "{F376DBEE-4CAE-41BA-ADD9-B2910AC95DEC}",
            ["num"] = 6
          },
          [7] = {
            ["CLSID"] = "{DB769D48-67D7-42ED-A2BE-108D566C8B1E}",
            ["num"] = 7
          },
          [8] = {
            ["CLSID"] = "{5CE2FF2A-645A-4197-B48D-8720AC69394F}",
            ["num"] = 8
          },
          [9] = {
            ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}",
            ["num"] = 9
          }
        }
      }
    },
    ["persistence"] = {
      ["autosave_period"] = 300,
      ["db_path"] = "dmt_campaign.sqlite",
      ["enabled"] = false,
      ["slot"] = "default"
    },
    ["reserves"] = {
      ["farp_heli"] = 4,
      ["farp_transport"] = 2,
      ["per_base"] = {
        ["escort"] = 2,
        ["heli"] = 6,
        ["recon"] = 1,
        ["striker"] = 4,
        ["transport"] = 3,
        ["vehicle"] = 2
      }
    },
    ["statics"] = {
      ["farp"] = {
        ["category"] = "Heliports",
        ["shape_name"] = "<verified four-slot FARP shape>",
        ["type"] = "FARP"
      },
      ["kinds"] = {
        ["command"] = {
          ["cat"] = "Fortifications",
          ["label"] = "Command Post",
          ["shape"] = "ComCenter",
          ["spawn"] = "static",
          ["type"] = ".Command Center"
        },
        ["depot"] = {
          ["cat"] = "Cargos",
          ["label"] = "Supply Depot",
          ["shape"] = "M92_Container_10ft",
          ["spawn"] = "static",
          ["type"] = "M92_10Ft_Container"
        },
        ["factory"] = {
          ["cat"] = "Fortifications",
          ["label"] = "Munitions Factory",
          ["shape"] = "kotelnaya_a",
          ["spawn"] = "static",
          ["type"] = "Boiler-house A"
        },
        ["fuel"] = {
          ["cat"] = "Fortifications",
          ["label"] = "Fuel Depot",
          ["shape"] = "GSM Rus",
          ["spawn"] = "static",
          ["type"] = "FARP Fuel Depot"
        },
        ["radar"] = {
          ["label"] = "Radar/EWR",
          ["spawn"] = "unit",
          ["unit"] = {
            [1] = "55G6 EWR",
            [2] = "Hawk sr"
          }
        },
        ["refinery"] = {
          ["cat"] = "Fortifications",
          ["label"] = "Oil Refinery",
          ["shape"] = "GSM Rus",
          ["spawn"] = "static",
          ["type"] = "FARP Fuel Depot"
        }
      },
      ["palette"] = {
        ["ammo"] = {
          [1] = ".Ammunition depot",
          [2] = "SkladC",
          [3] = "Warehouses"
        },
        ["bunker"] = {
          [1] = "FARP CP Blindage",
          [2] = "kp_ug",
          [3] = "Fortifications"
        },
        ["command"] = {
          [1] = ".Command Center",
          [2] = "ComCenter",
          [3] = "Fortifications"
        },
        ["container"] = {
          [1] = "M92_10Ft_Container",
          [2] = "M92_Container_10ft",
          [3] = "Cargos"
        },
        ["factory"] = {
          [1] = "Boiler-house A",
          [2] = "kotelnaya_a",
          [3] = "Fortifications"
        },
        ["fuel"] = {
          [1] = "FARP Fuel Depot",
          [2] = "GSM Rus",
          [3] = "Fortifications"
        },
        ["fueltank"] = {
          [1] = "Tank",
          [2] = "bak",
          [3] = "Warehouses"
        },
        ["warehouse"] = {
          [1] = "Warehouse",
          [2] = "sklad",
          [3] = "Warehouses"
        }
      }
    },
    ["theatre"] = {
      ["farp_activation"] = true,
      ["farp_front_dist"] = 260000,
      ["fixed_wing_per_side"] = 2,
      ["front_dist"] = 140000
    },
    ["types"] = {
      ["aircraft"] = {
        [1] = {
          ["attack_heli"] = "Mi-24V",
          ["bda_heli"] = "Mi-8MT",
          ["escort"] = "Su-27",
          ["recon"] = "Su-27",
          ["striker"] = "Su-25T",
          ["transport_fw"] = "An-26B",
          ["transport_fw_heavy"] = "IL-76MD",
          ["transport_heli"] = "Mi-8MT"
        },
        [2] = {
          ["attack_heli"] = "AH-64D",
          ["bda_heli"] = "UH-60A",
          ["escort"] = "F-15C",
          ["recon"] = "F-15C",
          ["striker"] = "F-16C bl.52d",
          ["transport_fw"] = "C-130",
          ["transport_fw_heavy"] = "C-17A",
          ["transport_heli"] = "UH-60A"
        }
      },
      ["ground"] = {
        ["aaa"] = {
          [1] = "ZSU-23-4 Shilka",
          [2] = "Vulcan"
        },
        ["arty_slots"] = {
          [1] = {
            [1] = "M-109",
            [2] = "SAU Msta"
          },
          [2] = {
            [1] = "M-109",
            [2] = "SAU Msta"
          },
          [3] = {
            [1] = "M 818",
            [2] = "Ural-375"
          },
          [4] = {
            [1] = "M1043 HMMWV Armament",
            [2] = "UAZ-469"
          }
        },
        ["ewr"] = {
          [1] = "55G6 EWR",
          [2] = "Hawk sr"
        },
        ["garrison"] = {
          [1] = {
            [1] = "T-80UD",
            [2] = "BMP-2",
            [3] = "BMP-2",
            [4] = "BTR-80"
          },
          [2] = {
            [1] = "M-1 Abrams",
            [2] = "M2A2 Bradley",
            [3] = "M2A2 Bradley",
            [4] = "M1043 HMMWV Armament"
          }
        },
        ["infantry"] = {
          [1] = "Infantry AK",
          [2] = "Soldier M4"
        },
        ["mlrs_slots"] = {
          [1] = {
            [1] = "MLRS",
            [2] = "Grad-URAL"
          },
          [2] = {
            [1] = "MLRS",
            [2] = "Grad-URAL"
          },
          [3] = {
            [1] = "M 818",
            [2] = "Ural-375"
          },
          [4] = {
            [1] = "M1043 HMMWV Armament",
            [2] = "UAZ-469"
          }
        },
        ["primary_slots"] = {
          [1] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [2] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [3] = {
            [1] = "M2A2 Bradley",
            [2] = "BMP-2"
          },
          [4] = {
            [1] = "M1097 Avenger",
            [2] = "2S6 Tunguska"
          },
          [5] = {
            [1] = "M2A2 Bradley",
            [2] = "BMP-3"
          },
          [6] = {
            [1] = "M48 Chaparral",
            [2] = "Strela-10M3"
          },
          [7] = {
            [1] = "M-113",
            [2] = "BTR-80"
          },
          [8] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [9] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [10] = {
            [1] = "M2A2 Bradley",
            [2] = "BMP-2"
          },
          [11] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [12] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [13] = {
            [1] = "M-113",
            [2] = "BTR-80"
          },
          [14] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [15] = {
            [1] = "M-113",
            [2] = "BTR-80"
          },
          [16] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          }
        },
        ["sam"] = {
          [1] = {
            [1] = "Kub 1S91 str",
            [2] = "Kub 2P25 ln"
          },
          [2] = {
            [1] = "Roland ADS"
          }
        },
        ["secondary_slots"] = {
          [1] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [2] = {
            [1] = "M48 Chaparral",
            [2] = "Strela-10M3"
          },
          [3] = {
            [1] = "M2A2 Bradley",
            [2] = "BMP-3"
          },
          [4] = {
            [1] = "M 818",
            [2] = "Ural-375"
          },
          [5] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [6] = {
            [1] = "M978 HEMTT Tanker",
            [2] = "ATZ-10"
          },
          [7] = {
            [1] = "M1043 HMMWV Armament",
            [2] = "BRDM-2"
          },
          [8] = {
            [1] = "M-113",
            [2] = "BTR-80"
          },
          [9] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [10] = {
            [1] = "M 818",
            [2] = "Ural-375"
          },
          [11] = {
            [1] = "M-113",
            [2] = "BTR-80"
          },
          [12] = {
            [1] = "M48 Chaparral",
            [2] = "Strela-10M3"
          },
          [13] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [14] = {
            [1] = "M978 HEMTT Tanker",
            [2] = "ATZ-10"
          },
          [15] = {
            [1] = "M48 Chaparral",
            [2] = "Strela-10M3"
          },
          [16] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          }
        }
      }
    }
  } },
  ["config non-table override true"] = { value = {
    ["countries"] = {
      [1] = 81,
      [2] = 80
    },
    ["defenses"] = {
      ["firing_points"] = {
        ["airbase"] = 4,
        ["farp"] = 2,
        ["installation"] = 2
      },
      ["group"] = {
        [1] = {
          [1] = "2S6 Tunguska",
          [2] = "Strela-10M3"
        },
        [2] = {
          [1] = "M48 Chaparral",
          [2] = "Vulcan"
        }
      },
      ["groups_per"] = {
        ["airbase"] = 3,
        ["farp"] = 1,
        ["installation"] = 1
      },
      ["manpad"] = {
        [1] = "SA-18 Igla manpad",
        [2] = "Soldier stinger"
      },
      ["mg"] = {
        [1] = "Infantry AK",
        [2] = "Soldier M4"
      },
      ["ring_radius"] = 1500
    },
    ["mode"] = "campaign",
    ["payloads"] = {
      [1] = {
        ["attack_heli"] = {
          [1] = {
            ["CLSID"] = "{B919B0F4-7C25-455E-9A02-CEA51DB895E3}",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}",
            ["num"] = 4
          },
          [5] = {
            ["CLSID"] = "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}",
            ["num"] = 5
          },
          [6] = {
            ["CLSID"] = "{B919B0F4-7C25-455E-9A02-CEA51DB895E3}",
            ["num"] = 6
          }
        },
        ["escort"] = {
          [1] = {
            ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{B79C379A-9E87-4E50-A1EE-7F7E29C2E87A}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}",
            ["num"] = 4
          },
          [5] = {
            ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}",
            ["num"] = 5
          },
          [6] = {
            ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}",
            ["num"] = 6
          },
          [7] = {
            ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}",
            ["num"] = 7
          },
          [8] = {
            ["CLSID"] = "{B79C379A-9E87-4E50-A1EE-7F7E29C2E87A}",
            ["num"] = 8
          },
          [9] = {
            ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 9
          },
          [10] = {
            ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 10
          }
        },
        ["striker"] = {
          [1] = {
            ["CLSID"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82D}",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{CBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{E8D4652F-FD48-45B7-BA5B-2AE05BB5A9CF}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "{601C99F7-9AF3-4ed7-A565-F8B8EC0D7AAC}",
            ["num"] = 5
          },
          [5] = {
            ["CLSID"] = "{601C99F7-9AF3-4ed7-A565-F8B8EC0D7AAC}",
            ["num"] = 7
          },
          [6] = {
            ["CLSID"] = "{E8D4652F-FD48-45B7-BA5B-2AE05BB5A9CF}",
            ["num"] = 9
          },
          [7] = {
            ["CLSID"] = "{CBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 10
          },
          [8] = {
            ["CLSID"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82C}",
            ["num"] = 11
          }
        }
      },
      [2] = {
        ["attack_heli"] = {
          [1] = {
            ["CLSID"] = "M261_MK151",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{88D18A5E-99C8-4B04-B40B-1C02F2018B6E}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{88D18A5E-99C8-4B04-B40B-1C02F2018B6E}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "M261_MK151",
            ["num"] = 4
          },
          [5] = {
            ["CLSID"] = "{IAFS_ComboPak_100}",
            ["num"] = 5
          },
          [6] = {
            ["CLSID"] = "{AN_APG_78}",
            ["num"] = 6
          }
        },
        ["escort"] = {
          [1] = {
            ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{E1F29B21-F291-4589-9FD8-3272EEC69506}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "{C8E06185-7CD6-4C90-959F-044679E90751}",
            ["num"] = 4
          },
          [5] = {
            ["CLSID"] = "{C8E06185-7CD6-4C90-959F-044679E90751}",
            ["num"] = 5
          },
          [6] = {
            ["CLSID"] = "{E1F29B21-F291-4589-9FD8-3272EEC69506}",
            ["num"] = 6
          },
          [7] = {
            ["CLSID"] = "{C8E06185-7CD6-4C90-959F-044679E90751}",
            ["num"] = 7
          },
          [8] = {
            ["CLSID"] = "{C8E06185-7CD6-4C90-959F-044679E90751}",
            ["num"] = 8
          },
          [9] = {
            ["CLSID"] = "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}",
            ["num"] = 9
          },
          [10] = {
            ["CLSID"] = "{E1F29B21-F291-4589-9FD8-3272EEC69506}",
            ["num"] = 10
          },
          [11] = {
            ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}",
            ["num"] = 11
          }
        },
        ["striker"] = {
          [1] = {
            ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{5CE2FF2A-645A-4197-B48D-8720AC69394F}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{DB769D48-67D7-42ED-A2BE-108D566C8B1E}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "{F376DBEE-4CAE-41BA-ADD9-B2910AC95DEC}",
            ["num"] = 4
          },
          [5] = {
            ["CLSID"] = "{A111396E-D3E8-4b9c-8AC9-2432489304D5}",
            ["num"] = 5
          },
          [6] = {
            ["CLSID"] = "{F376DBEE-4CAE-41BA-ADD9-B2910AC95DEC}",
            ["num"] = 6
          },
          [7] = {
            ["CLSID"] = "{DB769D48-67D7-42ED-A2BE-108D566C8B1E}",
            ["num"] = 7
          },
          [8] = {
            ["CLSID"] = "{5CE2FF2A-645A-4197-B48D-8720AC69394F}",
            ["num"] = 8
          },
          [9] = {
            ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}",
            ["num"] = 9
          }
        }
      }
    },
    ["persistence"] = {
      ["autosave_period"] = 300,
      ["db_path"] = "dmt_campaign.sqlite",
      ["enabled"] = false,
      ["slot"] = "default"
    },
    ["reserves"] = {
      ["farp_heli"] = 4,
      ["farp_transport"] = 2,
      ["per_base"] = {
        ["escort"] = 2,
        ["heli"] = 6,
        ["recon"] = 1,
        ["striker"] = 4,
        ["transport"] = 3,
        ["vehicle"] = 2
      }
    },
    ["statics"] = {
      ["farp"] = {
        ["category"] = "Heliports",
        ["shape_name"] = "<verified four-slot FARP shape>",
        ["type"] = "FARP"
      },
      ["kinds"] = {
        ["command"] = {
          ["cat"] = "Fortifications",
          ["label"] = "Command Post",
          ["shape"] = "ComCenter",
          ["spawn"] = "static",
          ["type"] = ".Command Center"
        },
        ["depot"] = {
          ["cat"] = "Cargos",
          ["label"] = "Supply Depot",
          ["shape"] = "M92_Container_10ft",
          ["spawn"] = "static",
          ["type"] = "M92_10Ft_Container"
        },
        ["factory"] = {
          ["cat"] = "Fortifications",
          ["label"] = "Munitions Factory",
          ["shape"] = "kotelnaya_a",
          ["spawn"] = "static",
          ["type"] = "Boiler-house A"
        },
        ["fuel"] = {
          ["cat"] = "Fortifications",
          ["label"] = "Fuel Depot",
          ["shape"] = "GSM Rus",
          ["spawn"] = "static",
          ["type"] = "FARP Fuel Depot"
        },
        ["radar"] = {
          ["label"] = "Radar/EWR",
          ["spawn"] = "unit",
          ["unit"] = {
            [1] = "55G6 EWR",
            [2] = "Hawk sr"
          }
        },
        ["refinery"] = {
          ["cat"] = "Fortifications",
          ["label"] = "Oil Refinery",
          ["shape"] = "GSM Rus",
          ["spawn"] = "static",
          ["type"] = "FARP Fuel Depot"
        }
      },
      ["palette"] = {
        ["ammo"] = {
          [1] = ".Ammunition depot",
          [2] = "SkladC",
          [3] = "Warehouses"
        },
        ["bunker"] = {
          [1] = "FARP CP Blindage",
          [2] = "kp_ug",
          [3] = "Fortifications"
        },
        ["command"] = {
          [1] = ".Command Center",
          [2] = "ComCenter",
          [3] = "Fortifications"
        },
        ["container"] = {
          [1] = "M92_10Ft_Container",
          [2] = "M92_Container_10ft",
          [3] = "Cargos"
        },
        ["factory"] = {
          [1] = "Boiler-house A",
          [2] = "kotelnaya_a",
          [3] = "Fortifications"
        },
        ["fuel"] = {
          [1] = "FARP Fuel Depot",
          [2] = "GSM Rus",
          [3] = "Fortifications"
        },
        ["fueltank"] = {
          [1] = "Tank",
          [2] = "bak",
          [3] = "Warehouses"
        },
        ["warehouse"] = {
          [1] = "Warehouse",
          [2] = "sklad",
          [3] = "Warehouses"
        }
      }
    },
    ["theatre"] = {
      ["farp_activation"] = true,
      ["farp_front_dist"] = 260000,
      ["fixed_wing_per_side"] = 2,
      ["front_dist"] = 140000
    },
    ["types"] = {
      ["aircraft"] = {
        [1] = {
          ["attack_heli"] = "Mi-24V",
          ["bda_heli"] = "Mi-8MT",
          ["escort"] = "Su-27",
          ["recon"] = "Su-27",
          ["striker"] = "Su-25T",
          ["transport_fw"] = "An-26B",
          ["transport_fw_heavy"] = "IL-76MD",
          ["transport_heli"] = "Mi-8MT"
        },
        [2] = {
          ["attack_heli"] = "AH-64D",
          ["bda_heli"] = "UH-60A",
          ["escort"] = "F-15C",
          ["recon"] = "F-15C",
          ["striker"] = "F-16C bl.52d",
          ["transport_fw"] = "C-130",
          ["transport_fw_heavy"] = "C-17A",
          ["transport_heli"] = "UH-60A"
        }
      },
      ["ground"] = {
        ["aaa"] = {
          [1] = "ZSU-23-4 Shilka",
          [2] = "Vulcan"
        },
        ["arty_slots"] = {
          [1] = {
            [1] = "M-109",
            [2] = "SAU Msta"
          },
          [2] = {
            [1] = "M-109",
            [2] = "SAU Msta"
          },
          [3] = {
            [1] = "M 818",
            [2] = "Ural-375"
          },
          [4] = {
            [1] = "M1043 HMMWV Armament",
            [2] = "UAZ-469"
          }
        },
        ["ewr"] = {
          [1] = "55G6 EWR",
          [2] = "Hawk sr"
        },
        ["garrison"] = {
          [1] = {
            [1] = "T-80UD",
            [2] = "BMP-2",
            [3] = "BMP-2",
            [4] = "BTR-80"
          },
          [2] = {
            [1] = "M-1 Abrams",
            [2] = "M2A2 Bradley",
            [3] = "M2A2 Bradley",
            [4] = "M1043 HMMWV Armament"
          }
        },
        ["infantry"] = {
          [1] = "Infantry AK",
          [2] = "Soldier M4"
        },
        ["mlrs_slots"] = {
          [1] = {
            [1] = "MLRS",
            [2] = "Grad-URAL"
          },
          [2] = {
            [1] = "MLRS",
            [2] = "Grad-URAL"
          },
          [3] = {
            [1] = "M 818",
            [2] = "Ural-375"
          },
          [4] = {
            [1] = "M1043 HMMWV Armament",
            [2] = "UAZ-469"
          }
        },
        ["primary_slots"] = {
          [1] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [2] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [3] = {
            [1] = "M2A2 Bradley",
            [2] = "BMP-2"
          },
          [4] = {
            [1] = "M1097 Avenger",
            [2] = "2S6 Tunguska"
          },
          [5] = {
            [1] = "M2A2 Bradley",
            [2] = "BMP-3"
          },
          [6] = {
            [1] = "M48 Chaparral",
            [2] = "Strela-10M3"
          },
          [7] = {
            [1] = "M-113",
            [2] = "BTR-80"
          },
          [8] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [9] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [10] = {
            [1] = "M2A2 Bradley",
            [2] = "BMP-2"
          },
          [11] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [12] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [13] = {
            [1] = "M-113",
            [2] = "BTR-80"
          },
          [14] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [15] = {
            [1] = "M-113",
            [2] = "BTR-80"
          },
          [16] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          }
        },
        ["sam"] = {
          [1] = {
            [1] = "Kub 1S91 str",
            [2] = "Kub 2P25 ln"
          },
          [2] = {
            [1] = "Roland ADS"
          }
        },
        ["secondary_slots"] = {
          [1] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [2] = {
            [1] = "M48 Chaparral",
            [2] = "Strela-10M3"
          },
          [3] = {
            [1] = "M2A2 Bradley",
            [2] = "BMP-3"
          },
          [4] = {
            [1] = "M 818",
            [2] = "Ural-375"
          },
          [5] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [6] = {
            [1] = "M978 HEMTT Tanker",
            [2] = "ATZ-10"
          },
          [7] = {
            [1] = "M1043 HMMWV Armament",
            [2] = "BRDM-2"
          },
          [8] = {
            [1] = "M-113",
            [2] = "BTR-80"
          },
          [9] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [10] = {
            [1] = "M 818",
            [2] = "Ural-375"
          },
          [11] = {
            [1] = "M-113",
            [2] = "BTR-80"
          },
          [12] = {
            [1] = "M48 Chaparral",
            [2] = "Strela-10M3"
          },
          [13] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [14] = {
            [1] = "M978 HEMTT Tanker",
            [2] = "ATZ-10"
          },
          [15] = {
            [1] = "M48 Chaparral",
            [2] = "Strela-10M3"
          },
          [16] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          }
        }
      }
    }
  } },
  ["config non-table override bad"] = { value = {
    ["countries"] = {
      [1] = 81,
      [2] = 80
    },
    ["defenses"] = {
      ["firing_points"] = {
        ["airbase"] = 4,
        ["farp"] = 2,
        ["installation"] = 2
      },
      ["group"] = {
        [1] = {
          [1] = "2S6 Tunguska",
          [2] = "Strela-10M3"
        },
        [2] = {
          [1] = "M48 Chaparral",
          [2] = "Vulcan"
        }
      },
      ["groups_per"] = {
        ["airbase"] = 3,
        ["farp"] = 1,
        ["installation"] = 1
      },
      ["manpad"] = {
        [1] = "SA-18 Igla manpad",
        [2] = "Soldier stinger"
      },
      ["mg"] = {
        [1] = "Infantry AK",
        [2] = "Soldier M4"
      },
      ["ring_radius"] = 1500
    },
    ["mode"] = "campaign",
    ["payloads"] = {
      [1] = {
        ["attack_heli"] = {
          [1] = {
            ["CLSID"] = "{B919B0F4-7C25-455E-9A02-CEA51DB895E3}",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}",
            ["num"] = 4
          },
          [5] = {
            ["CLSID"] = "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}",
            ["num"] = 5
          },
          [6] = {
            ["CLSID"] = "{B919B0F4-7C25-455E-9A02-CEA51DB895E3}",
            ["num"] = 6
          }
        },
        ["escort"] = {
          [1] = {
            ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{B79C379A-9E87-4E50-A1EE-7F7E29C2E87A}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}",
            ["num"] = 4
          },
          [5] = {
            ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}",
            ["num"] = 5
          },
          [6] = {
            ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}",
            ["num"] = 6
          },
          [7] = {
            ["CLSID"] = "{E8069896-8435-4B90-95C0-01A03AE6E400}",
            ["num"] = 7
          },
          [8] = {
            ["CLSID"] = "{B79C379A-9E87-4E50-A1EE-7F7E29C2E87A}",
            ["num"] = 8
          },
          [9] = {
            ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 9
          },
          [10] = {
            ["CLSID"] = "{FBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 10
          }
        },
        ["striker"] = {
          [1] = {
            ["CLSID"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82D}",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{CBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{E8D4652F-FD48-45B7-BA5B-2AE05BB5A9CF}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "{601C99F7-9AF3-4ed7-A565-F8B8EC0D7AAC}",
            ["num"] = 5
          },
          [5] = {
            ["CLSID"] = "{601C99F7-9AF3-4ed7-A565-F8B8EC0D7AAC}",
            ["num"] = 7
          },
          [6] = {
            ["CLSID"] = "{E8D4652F-FD48-45B7-BA5B-2AE05BB5A9CF}",
            ["num"] = 9
          },
          [7] = {
            ["CLSID"] = "{CBC29BFE-3D24-4C64-B81D-941239D12249}",
            ["num"] = 10
          },
          [8] = {
            ["CLSID"] = "{44EE8698-89F9-48EE-AF36-5FD31896A82C}",
            ["num"] = 11
          }
        }
      },
      [2] = {
        ["attack_heli"] = {
          [1] = {
            ["CLSID"] = "M261_MK151",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{88D18A5E-99C8-4B04-B40B-1C02F2018B6E}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{88D18A5E-99C8-4B04-B40B-1C02F2018B6E}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "M261_MK151",
            ["num"] = 4
          },
          [5] = {
            ["CLSID"] = "{IAFS_ComboPak_100}",
            ["num"] = 5
          },
          [6] = {
            ["CLSID"] = "{AN_APG_78}",
            ["num"] = 6
          }
        },
        ["escort"] = {
          [1] = {
            ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{E1F29B21-F291-4589-9FD8-3272EEC69506}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "{C8E06185-7CD6-4C90-959F-044679E90751}",
            ["num"] = 4
          },
          [5] = {
            ["CLSID"] = "{C8E06185-7CD6-4C90-959F-044679E90751}",
            ["num"] = 5
          },
          [6] = {
            ["CLSID"] = "{E1F29B21-F291-4589-9FD8-3272EEC69506}",
            ["num"] = 6
          },
          [7] = {
            ["CLSID"] = "{C8E06185-7CD6-4C90-959F-044679E90751}",
            ["num"] = 7
          },
          [8] = {
            ["CLSID"] = "{C8E06185-7CD6-4C90-959F-044679E90751}",
            ["num"] = 8
          },
          [9] = {
            ["CLSID"] = "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}",
            ["num"] = 9
          },
          [10] = {
            ["CLSID"] = "{E1F29B21-F291-4589-9FD8-3272EEC69506}",
            ["num"] = 10
          },
          [11] = {
            ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}",
            ["num"] = 11
          }
        },
        ["striker"] = {
          [1] = {
            ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}",
            ["num"] = 1
          },
          [2] = {
            ["CLSID"] = "{5CE2FF2A-645A-4197-B48D-8720AC69394F}",
            ["num"] = 2
          },
          [3] = {
            ["CLSID"] = "{DB769D48-67D7-42ED-A2BE-108D566C8B1E}",
            ["num"] = 3
          },
          [4] = {
            ["CLSID"] = "{F376DBEE-4CAE-41BA-ADD9-B2910AC95DEC}",
            ["num"] = 4
          },
          [5] = {
            ["CLSID"] = "{A111396E-D3E8-4b9c-8AC9-2432489304D5}",
            ["num"] = 5
          },
          [6] = {
            ["CLSID"] = "{F376DBEE-4CAE-41BA-ADD9-B2910AC95DEC}",
            ["num"] = 6
          },
          [7] = {
            ["CLSID"] = "{DB769D48-67D7-42ED-A2BE-108D566C8B1E}",
            ["num"] = 7
          },
          [8] = {
            ["CLSID"] = "{5CE2FF2A-645A-4197-B48D-8720AC69394F}",
            ["num"] = 8
          },
          [9] = {
            ["CLSID"] = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}",
            ["num"] = 9
          }
        }
      }
    },
    ["persistence"] = {
      ["autosave_period"] = 300,
      ["db_path"] = "dmt_campaign.sqlite",
      ["enabled"] = false,
      ["slot"] = "default"
    },
    ["reserves"] = {
      ["farp_heli"] = 4,
      ["farp_transport"] = 2,
      ["per_base"] = {
        ["escort"] = 2,
        ["heli"] = 6,
        ["recon"] = 1,
        ["striker"] = 4,
        ["transport"] = 3,
        ["vehicle"] = 2
      }
    },
    ["statics"] = {
      ["farp"] = {
        ["category"] = "Heliports",
        ["shape_name"] = "<verified four-slot FARP shape>",
        ["type"] = "FARP"
      },
      ["kinds"] = {
        ["command"] = {
          ["cat"] = "Fortifications",
          ["label"] = "Command Post",
          ["shape"] = "ComCenter",
          ["spawn"] = "static",
          ["type"] = ".Command Center"
        },
        ["depot"] = {
          ["cat"] = "Cargos",
          ["label"] = "Supply Depot",
          ["shape"] = "M92_Container_10ft",
          ["spawn"] = "static",
          ["type"] = "M92_10Ft_Container"
        },
        ["factory"] = {
          ["cat"] = "Fortifications",
          ["label"] = "Munitions Factory",
          ["shape"] = "kotelnaya_a",
          ["spawn"] = "static",
          ["type"] = "Boiler-house A"
        },
        ["fuel"] = {
          ["cat"] = "Fortifications",
          ["label"] = "Fuel Depot",
          ["shape"] = "GSM Rus",
          ["spawn"] = "static",
          ["type"] = "FARP Fuel Depot"
        },
        ["radar"] = {
          ["label"] = "Radar/EWR",
          ["spawn"] = "unit",
          ["unit"] = {
            [1] = "55G6 EWR",
            [2] = "Hawk sr"
          }
        },
        ["refinery"] = {
          ["cat"] = "Fortifications",
          ["label"] = "Oil Refinery",
          ["shape"] = "GSM Rus",
          ["spawn"] = "static",
          ["type"] = "FARP Fuel Depot"
        }
      },
      ["palette"] = {
        ["ammo"] = {
          [1] = ".Ammunition depot",
          [2] = "SkladC",
          [3] = "Warehouses"
        },
        ["bunker"] = {
          [1] = "FARP CP Blindage",
          [2] = "kp_ug",
          [3] = "Fortifications"
        },
        ["command"] = {
          [1] = ".Command Center",
          [2] = "ComCenter",
          [3] = "Fortifications"
        },
        ["container"] = {
          [1] = "M92_10Ft_Container",
          [2] = "M92_Container_10ft",
          [3] = "Cargos"
        },
        ["factory"] = {
          [1] = "Boiler-house A",
          [2] = "kotelnaya_a",
          [3] = "Fortifications"
        },
        ["fuel"] = {
          [1] = "FARP Fuel Depot",
          [2] = "GSM Rus",
          [3] = "Fortifications"
        },
        ["fueltank"] = {
          [1] = "Tank",
          [2] = "bak",
          [3] = "Warehouses"
        },
        ["warehouse"] = {
          [1] = "Warehouse",
          [2] = "sklad",
          [3] = "Warehouses"
        }
      }
    },
    ["theatre"] = {
      ["farp_activation"] = true,
      ["farp_front_dist"] = 260000,
      ["fixed_wing_per_side"] = 2,
      ["front_dist"] = 140000
    },
    ["types"] = {
      ["aircraft"] = {
        [1] = {
          ["attack_heli"] = "Mi-24V",
          ["bda_heli"] = "Mi-8MT",
          ["escort"] = "Su-27",
          ["recon"] = "Su-27",
          ["striker"] = "Su-25T",
          ["transport_fw"] = "An-26B",
          ["transport_fw_heavy"] = "IL-76MD",
          ["transport_heli"] = "Mi-8MT"
        },
        [2] = {
          ["attack_heli"] = "AH-64D",
          ["bda_heli"] = "UH-60A",
          ["escort"] = "F-15C",
          ["recon"] = "F-15C",
          ["striker"] = "F-16C bl.52d",
          ["transport_fw"] = "C-130",
          ["transport_fw_heavy"] = "C-17A",
          ["transport_heli"] = "UH-60A"
        }
      },
      ["ground"] = {
        ["aaa"] = {
          [1] = "ZSU-23-4 Shilka",
          [2] = "Vulcan"
        },
        ["arty_slots"] = {
          [1] = {
            [1] = "M-109",
            [2] = "SAU Msta"
          },
          [2] = {
            [1] = "M-109",
            [2] = "SAU Msta"
          },
          [3] = {
            [1] = "M 818",
            [2] = "Ural-375"
          },
          [4] = {
            [1] = "M1043 HMMWV Armament",
            [2] = "UAZ-469"
          }
        },
        ["ewr"] = {
          [1] = "55G6 EWR",
          [2] = "Hawk sr"
        },
        ["garrison"] = {
          [1] = {
            [1] = "T-80UD",
            [2] = "BMP-2",
            [3] = "BMP-2",
            [4] = "BTR-80"
          },
          [2] = {
            [1] = "M-1 Abrams",
            [2] = "M2A2 Bradley",
            [3] = "M2A2 Bradley",
            [4] = "M1043 HMMWV Armament"
          }
        },
        ["infantry"] = {
          [1] = "Infantry AK",
          [2] = "Soldier M4"
        },
        ["mlrs_slots"] = {
          [1] = {
            [1] = "MLRS",
            [2] = "Grad-URAL"
          },
          [2] = {
            [1] = "MLRS",
            [2] = "Grad-URAL"
          },
          [3] = {
            [1] = "M 818",
            [2] = "Ural-375"
          },
          [4] = {
            [1] = "M1043 HMMWV Armament",
            [2] = "UAZ-469"
          }
        },
        ["primary_slots"] = {
          [1] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [2] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [3] = {
            [1] = "M2A2 Bradley",
            [2] = "BMP-2"
          },
          [4] = {
            [1] = "M1097 Avenger",
            [2] = "2S6 Tunguska"
          },
          [5] = {
            [1] = "M2A2 Bradley",
            [2] = "BMP-3"
          },
          [6] = {
            [1] = "M48 Chaparral",
            [2] = "Strela-10M3"
          },
          [7] = {
            [1] = "M-113",
            [2] = "BTR-80"
          },
          [8] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [9] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [10] = {
            [1] = "M2A2 Bradley",
            [2] = "BMP-2"
          },
          [11] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [12] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [13] = {
            [1] = "M-113",
            [2] = "BTR-80"
          },
          [14] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [15] = {
            [1] = "M-113",
            [2] = "BTR-80"
          },
          [16] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          }
        },
        ["sam"] = {
          [1] = {
            [1] = "Kub 1S91 str",
            [2] = "Kub 2P25 ln"
          },
          [2] = {
            [1] = "Roland ADS"
          }
        },
        ["secondary_slots"] = {
          [1] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [2] = {
            [1] = "M48 Chaparral",
            [2] = "Strela-10M3"
          },
          [3] = {
            [1] = "M2A2 Bradley",
            [2] = "BMP-3"
          },
          [4] = {
            [1] = "M 818",
            [2] = "Ural-375"
          },
          [5] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [6] = {
            [1] = "M978 HEMTT Tanker",
            [2] = "ATZ-10"
          },
          [7] = {
            [1] = "M1043 HMMWV Armament",
            [2] = "BRDM-2"
          },
          [8] = {
            [1] = "M-113",
            [2] = "BTR-80"
          },
          [9] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [10] = {
            [1] = "M 818",
            [2] = "Ural-375"
          },
          [11] = {
            [1] = "M-113",
            [2] = "BTR-80"
          },
          [12] = {
            [1] = "M48 Chaparral",
            [2] = "Strela-10M3"
          },
          [13] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          },
          [14] = {
            [1] = "M978 HEMTT Tanker",
            [2] = "ATZ-10"
          },
          [15] = {
            [1] = "M48 Chaparral",
            [2] = "Strela-10M3"
          },
          [16] = {
            [1] = "M-1 Abrams",
            [2] = "T-80UD"
          }
        }
      }
    }
  } },
}
