# Qdrant 内存优化建议

## 当前配置分析

根据您提供的配置，当前内存占用大的主要原因：

1. **向量未存储在磁盘上**：`vectors.on_disk` 未设置（默认 false），所有向量都在内存中
2. **HNSW 索引在内存中**：`hnsw_config.on_disk: false`，HNSW 索引占用大量内存
3. **未使用量化**：`quantization_config: null`，没有压缩向量
4. **文本索引在内存中**：`file_name` 字段的 `on_disk: false`

## 优化方案

根据 [Qdrant 官方优化文档](https://qdrant.tech/documentation/guides/optimize/)，针对**高精度 + 低内存使用**场景，推荐以下配置：

### 方案一：基础磁盘存储（推荐）

将向量和 HNSW 索引都存储在磁盘上，大幅降低内存占用：

```json
{
  "params": {
    "vectors": {
      "dense": {
        "size": 1024,
        "distance": "Cosine",
        "on_disk": true
      }
    },
    "shard_number": 3,
    "replication_factor": 1,
    "write_consistency_factor": 1,
    "on_disk_payload": true,
    "sparse_vectors": {
      "sparse": {
        "modifier": "idf"
      }
    }
  },
  "hnsw_config": {
    "m": 16,
    "ef_construct": 100,
    "full_scan_threshold": 10000,
    "max_indexing_threads": 0,
    "on_disk": true
  },
  "optimizer_config": {
    "deleted_threshold": 0.2,
    "vacuum_min_vector_number": 1000,
    "default_segment_number": 0,
    "max_segment_size": null,
    "memmap_threshold": null,
    "indexing_threshold": 20000,
    "flush_interval_sec": 5,
    "max_optimization_threads": null
  },
  "wal_config": {
    "wal_capacity_mb": 32,
    "wal_segments_ahead": 0
  },
  "quantization_config": null,
  "strict_mode_config": {
    "enabled": false
  }
}
```

**主要变更：**
- ✅ `vectors.dense.on_disk: true` - 向量存储在磁盘
- ✅ `hnsw_config.on_disk: true` - HNSW 索引存储在磁盘

**效果：** 内存占用显著降低，但搜索速度会略有下降（取决于磁盘 IOPS）

### 方案二：磁盘存储 + 量化（平衡方案）

在方案一基础上添加量化，进一步降低内存并提升搜索速度：

```json
{
  "params": {
    "vectors": {
      "dense": {
        "size": 1024,
        "distance": "Cosine",
        "on_disk": true
      }
    },
    "shard_number": 3,
    "replication_factor": 1,
    "write_consistency_factor": 1,
    "on_disk_payload": true,
    "sparse_vectors": {
      "sparse": {
        "modifier": "idf"
      }
    }
  },
  "hnsw_config": {
    "m": 16,
    "ef_construct": 100,
    "full_scan_threshold": 10000,
    "max_indexing_threads": 0,
    "on_disk": true
  },
  "optimizer_config": {
    "deleted_threshold": 0.2,
    "vacuum_min_vector_number": 1000,
    "default_segment_number": 0,
    "max_segment_size": null,
    "memmap_threshold": null,
    "indexing_threshold": 20000,
    "flush_interval_sec": 5,
    "max_optimization_threads": null
  },
  "wal_config": {
    "wal_capacity_mb": 32,
    "wal_segments_ahead": 0
  },
  "quantization_config": {
    "scalar": {
      "type": "int8",
      "always_ram": false
    }
  },
  "strict_mode_config": {
    "enabled": false
  }
}
```

**主要变更：**
- ✅ `vectors.dense.on_disk: true`
- ✅ `hnsw_config.on_disk: true`
- ✅ `quantization_config.scalar.type: "int8"` - 使用 int8 量化压缩向量
- ✅ `quantization_config.scalar.always_ram: false` - 量化向量也在磁盘上

**效果：** 内存占用更低，搜索速度比纯磁盘存储更快

### 方案三：高速度 + 低内存（量化在内存）

如果希望搜索速度更快，可以将量化向量保留在内存中：

```json
{
  "params": {
    "vectors": {
      "dense": {
        "size": 1024,
        "distance": "Cosine",
        "on_disk": true
      }
    },
    "shard_number": 3,
    "replication_factor": 1,
    "write_consistency_factor": 1,
    "on_disk_payload": true,
    "sparse_vectors": {
      "sparse": {
        "modifier": "idf"
      }
    }
  },
  "hnsw_config": {
    "m": 16,
    "ef_construct": 100,
    "full_scan_threshold": 10000,
    "max_indexing_threads": 0,
    "on_disk": true
  },
  "optimizer_config": {
    "deleted_threshold": 0.2,
    "vacuum_min_vector_number": 1000,
    "default_segment_number": 0,
    "max_segment_size": null,
    "memmap_threshold": null,
    "indexing_threshold": 20000,
    "flush_interval_sec": 5,
    "max_optimization_threads": null
  },
  "wal_config": {
    "wal_capacity_mb": 32,
    "wal_segments_ahead": 0
  },
  "quantization_config": {
    "scalar": {
      "type": "int8",
      "always_ram": true
    }
  },
  "strict_mode_config": {
    "enabled": false
  }
}
```

**主要变更：**
- ✅ `vectors.dense.on_disk: true` - 原始向量在磁盘
- ✅ `hnsw_config.on_disk: true` - HNSW 索引在磁盘
- ✅ `quantization_config.scalar.always_ram: true` - 量化向量在内存（占用更少）

**效果：** 搜索速度快，内存占用适中（量化向量占用约原始向量的 1/4）

## Payload 索引优化

对于文本字段，也可以将索引存储在磁盘上：

```json
{
  "file_name": {
    "data_type": "text",
    "params": {
      "type": "text",
      "tokenizer": "multilingual",
      "min_token_len": 2,
      "max_token_len": 24,
      "lowercase": true,
      "on_disk": true
    },
    "points": 100
  }
}
```

**变更：** `file_name.params.on_disk: true`

## 应用优化配置

### 方法 1：更新现有 Collection（推荐）

如果 collection 已存在数据，需要先更新配置，然后重建索引：

```bash
# 1. 更新 collection 配置
curl -X PATCH "http://localhost:6333/collections/{collection_name}" \
  -H "Content-Type: application/json" \
  -d '{
    "vectors": {
      "dense": {
        "on_disk": true
      }
    },
    "hnsw_config": {
      "on_disk": true
    }
  }'

# 2. 触发索引重建（如果需要）
curl -X POST "http://localhost:6333/collections/{collection_name}/index"
```

### 方法 2：创建新 Collection

如果数据可以重新导入，建议创建新 collection 并应用优化配置。

## 性能影响

### 内存占用对比

| 配置 | 向量内存 | HNSW 内存 | 总内存占用 |
|------|---------|-----------|-----------|
| 当前配置 | 100% | 100% | **高** |
| 方案一（磁盘） | ~0% | ~0% | **低** |
| 方案二（磁盘+量化） | ~0% | ~0% | **很低** |
| 方案三（量化RAM） | ~0% | ~0% | **中**（量化向量在RAM） |

### 搜索速度影响

- **方案一**：搜索速度取决于磁盘 IOPS，通常比内存慢 2-10 倍
- **方案二**：搜索速度比方案一快，因为量化向量压缩后读取更快
- **方案三**：搜索速度最快，接近纯内存性能

## 建议

1. **优先使用方案一**：如果内存是主要瓶颈，先尝试基础磁盘存储
2. **需要更快速度时用方案三**：如果搜索速度要求高，使用量化+RAM 方案
3. **监控磁盘 IOPS**：使用 `fio` 工具测试磁盘性能，确保满足搜索延迟要求
4. **逐步优化**：先应用向量和 HNSW 的 `on_disk`，观察效果后再考虑量化

## 参考文档

- [Qdrant 性能优化指南](https://qdrant.tech/documentation/guides/optimize/)
- [量化配置文档](https://qdrant.tech/documentation/guides/quantization/)
