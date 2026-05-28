typedef struct packed {
  logic        valid;
  logic [5:0]  tag;
  logic [31:0] data;
} cdb_entry_t;
