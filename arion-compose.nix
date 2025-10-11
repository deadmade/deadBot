{ ...}: let
  # Configuration
  botInstances = 1;
  redisReplicas = 2;

  # Helper function to create bot services
  mkBotService = i: {
    service = {
      image = "dead-bot:latest"; # Will be overridden via flake overlay
      container_name = "dead-bot-${toString i}";
      environment = {
        BOT_INSTANCE_ID = toString i;
        REDIS_URL = "redis://redis-master:6379";
        RUST_LOG = "debug";
      };
      env_file = [".env"];
      depends_on = [
        "redis-master"
      ];
      restart = "unless-stopped";
    };
  };

  # Helper function to create Redis replica services
  mkRedisReplica = i: {
    service = {
      image = "redis:7-alpine";
      container_name = "redis-replica-${toString i}";
      command = [
        "redis-server"
        "--replicaof"
        "redis-master"
        "6379"
        "--appendonly"
        "yes"
      ];
      depends_on = ["redis-master"];
      restart = "unless-stopped";
      volumes = [
        "redis-replica-${toString i}-data:/data"
      ];
    };
  };

  # Generate bot services dynamically
  botServices = builtins.listToAttrs (
    map (i: {
      name = "dead-bot-${toString i}";
      value = mkBotService i;
    })
    (builtins.genList (x: x + 1) botInstances)
  );

  # Generate Redis replica services dynamically
  replicaServices = builtins.listToAttrs (
    map (i: {
      name = "redis-replica-${toString i}";
      value = mkRedisReplica i;
    })
    (builtins.genList (x: x + 1) redisReplicas)
  );
in {
  project.name = "deadbot-cluster";

  services =
    botServices
    // replicaServices
    // {
      # Redis Master
      redis-master = {
        service = {
          image = "redis:7-alpine";
          container_name = "redis-master";
          command = [
            "redis-server"
            "--appendonly"
            "yes"
            "--appendfsync"
            "everysec"
          ];
          ports = ["6379:6379"];
          restart = "unless-stopped";
          volumes = [
            "redis-master-data:/data"
          ];
          healthcheck = {
            test = ["CMD" "redis-cli" "ping"];
            interval = "30s";
            timeout = "10s";
            retries = 3;
            start_period = "30s";
          };
        };
      };

      # Redis Sentinel for high availability (optional but recommended)
      redis-sentinel = {
        service = {
          image = "redis:7-alpine";
          container_name = "redis-sentinel";
          command = [
            "redis-sentinel"
            "/etc/redis/sentinel.conf"
          ];
          depends_on = ["redis-master"];
          restart = "unless-stopped";
          volumes = [
            "./redis-sentinel.conf:/etc/redis/sentinel.conf:ro"
          ];
        };
      };
    };

  # Named volumes
  docker-compose.volumes =
    {
      redis-master-data = {};
    }
    // builtins.listToAttrs (
      map (i: {
        name = "redis-replica-${toString i}-data";
        value = {};
      })
      (builtins.genList (x: x + 1) redisReplicas)
    );
}
