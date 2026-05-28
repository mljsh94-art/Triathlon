add_library(npcsim STATIC
  lib/args_parser.cpp
  lib/difftest_client.cpp
)

target_include_directories(npcsim
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_compile_features(npcsim PUBLIC cxx_std_17)

option(NPC_BUILD_SIM_APP "Build npc_sim executable (requires generated Verilator model headers)." OFF)
if(NPC_BUILD_SIM_APP)
  add_executable(npc_sim
    npc_main.cpp
  )

  target_include_directories(npc_sim PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${PROJECT_SOURCE_DIR}/include
    ${PROJECT_SOURCE_DIR}/build/obj_dir
  )

  target_link_libraries(npc_sim PRIVATE
    npcsim
    dl
    readline
  )
endif()
