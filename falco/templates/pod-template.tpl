{{- define "falco.podTemplate" -}}
metadata:
  name: {{ include "falco.fullname" . }}
  labels:
    {{- include "falco.selectorLabels" . | nindent 4 }}
    {{- with .Values.podLabels }}
      {{- toYaml . | nindent 4 }}
    {{- end }}
  annotations:
    checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
    checksum/rules: {{ include (print $.Template.BasePath "/rules-configmap.yaml") . | sha256sum }}
    {{- if and .Values.certs (not .Values.certs.existingSecret) }}
    checksum/certs: {{ include (print $.Template.BasePath "/certs-secret.yaml") . | sha256sum }}
    {{- end }}
    {{- with .Values.podAnnotations }}
      {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  serviceAccountName: {{ include "falco.serviceAccountName" . }}
  {{- with .Values.podSecurityContext }}
  securityContext:
    {{- toYaml . | nindent 4}}
  {{- end }}
  {{- if .Values.driver.enabled }}
  {{- if and (eq .Values.driver.kind "ebpf") .Values.driver.ebpf.hostNetwork }}
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  {{- end }}
  {{- end }}
  {{- if .Values.podPriorityClassName }}
  priorityClassName: {{ .Values.podPriorityClassName }}
  {{- end }}
  {{- with .Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets: 
    {{- toYaml . | nindent 4 }}
  {{- end }}
  containers:
    - name: {{ .Chart.Name }}
      image: {{ include "falco.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
      securityContext:
        {{- include "falco.securityContext" . | nindent 8 }}
      args:
        - /bin/bash
        - -c
        - |
          set -euo pipefail
          flags=()
          # Check if gVisor is configured on the node.
          if [[ -f /host/run/containerd/runsc/config.toml ]]; then
            echo Configuring Falco+gVisor integration.
            /usr/bin/falco --gvisor-generate-config=/run/containerd/runsc/falco.sock > /host/run/containerd/runsc/pod-init.json
            if [[ -z $(grep pod-init-config /host/run/containerd/runsc/config.toml) ]]; then
              echo '  pod-init-config = "/run/containerd/runsc/pod-init.json"' >> /host/run/containerd/runsc/config.toml
            fi

            # Endpoint inside the container is different from outside, add
            # "/host" to the endpoint path inside the container.
            sed 's/"endpoint" : "\/run/"endpoint" : "\/host\/run/' /host/run/containerd/runsc/pod-init.json > /tmp/pod-init.json
            flags=(--gvisor-config /tmp/pod-init.json --gvisor-root /host/run/containerd/runsc/k8s.io)
            PATH=${PATH}:/host/home/containerd/usr/local/sbin
          fi
          /usr/bin/falco
          {{- with .Values.collectors }}
          {{- if .enabled }}
          {{- if .containerd.enabled }}
          - --cri
          - /run/containerd/containerd.sock
          {{- end }}
          {{- if .crio.enabled }}
          - --cri
          - /run/crio/crio.sock
          {{- end }}
          {{- if .kubernetes.enabled }}
          - -K
          - {{ .kubernetes.apiAuth }}
          - -k
          - {{ .kubernetes.apiUrl }}
          {{- if .kubernetes.enableNodeFilter }}
          - --k8s-node
          - "$(FALCO_K8S_NODE_NAME)"
          {{- end }}
          {{- end }}
          - -pk
          {{- end }}
          {{- end }}
          "${flags[@]}"
    {{- with .Values.extra.args }}
      {{- toYaml . | nindent 8 }}
    {{- end }}
      env:
        - name: FALCO_K8S_NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
      {{- if or (not .Values.driver.enabled) (and .Values.driver.loader.enabled .Values.driver.loader.initContainer.enabled) }}
        - name: SKIP_DRIVER_LOADER
          value:
      {{- end }}
      {{- if and .Values.driver.enabled (eq .Values.driver.kind "ebpf") }}
        - name: FALCO_BPF_PROBE
          value: {{ .Values.driver.ebpf.path }}
      {{- end }}
      {{- range $key, $value := .Values.extra.env }}
        - name: "{{ $key }}"
          value: "{{ $value }}"
      {{- end }}
      {{- if .Values.falco.webserver.enabled }}
      tty: {{ .Values.tty }}
      livenessProbe:
        initialDelaySeconds: {{ .Values.healthChecks.livenessProbe.initialDelaySeconds }}
        timeoutSeconds: {{ .Values.healthChecks.livenessProbe.timeoutSeconds }}
        periodSeconds: {{ .Values.healthChecks.livenessProbe.periodSeconds }}
        httpGet:
          path: {{ .Values.falco.webserver.k8s_healthz_endpoint }}
          port: {{ .Values.falco.webserver.listen_port }}
          {{- if .Values.falco.webserver.ssl_enabled }}
          scheme: HTTPS
          {{- end }}
      readinessProbe:
        initialDelaySeconds: {{ .Values.healthChecks.readinessProbe.initialDelaySeconds }}
        timeoutSeconds: {{ .Values.healthChecks.readinessProbe.timeoutSeconds }}
        periodSeconds: {{ .Values.healthChecks.readinessProbe.periodSeconds }}
        httpGet:
          path: {{ .Values.falco.webserver.k8s_healthz_endpoint }}
          port: {{ .Values.falco.webserver.listen_port }}
          {{- if .Values.falco.webserver.ssl_enabled }}
          scheme: HTTPS
          {{- end }}
      {{- end }}
      volumeMounts:
        - mountPath: /root/.falco
          name: root-falco-fs
        {{- if or .Values.driver.enabled .Values.mounts.enforceProcMount }}
        - mountPath: /host/proc
          name: proc-fs
        {{- end }}
        {{- if and .Values.driver.enabled (not .Values.driver.loader.initContainer.enabled) }}
          readOnly: true
        - mountPath: /host/boot
          name: boot-fs
          readOnly: true
        - mountPath: /host/lib/modules
          name: lib-modules
        - mountPath: /host/usr
          name: usr-fs
          readOnly: true
        - mountPath: /host/etc
          name: etc-fs
          readOnly: true
        {{- end }}
        {{- if and .Values.driver.enabled (eq .Values.driver.kind "module") }}
        - mountPath: /host/dev
          name: dev-fs
          readOnly: true
        {{- end }}
        {{- if and .Values.driver.enabled (and (eq .Values.driver.kind "ebpf") (contains "falco-no-driver" .Values.image.repository)) }}
        - name: debugfs
          mountPath: /sys/kernel/debug
        {{- end }}
        {{- with .Values.collectors }}
        {{- if .enabled }}
        {{- if .docker.enabled }}
        - mountPath: /host/var/run/docker.sock
          name: docker-socket
        {{- end }}
        {{- if .containerd.enabled }}
        - mountPath: /host/run/containerd/containerd.sock
          name: containerd-socket
        {{- end }}
        {{- if .crio.enabled }}
        - mountPath: /host/run/crio/crio.sock
          name: crio-socket
        {{- end }}
        {{- end }}
        {{- end }}
        - mountPath: /etc/falco
          name: config-volume
        {{- if .Values.customRules }}
        - mountPath: /etc/falco/rules.d
          name: rules-volume
        {{- end }}
        {{- if or .Values.certs.existingSecret (and .Values.certs.server.key .Values.certs.server.crt .Values.certs.ca.crt) }}
        - mountPath: /etc/falco/certs
          name: certs-volume
          readOnly: true
        {{- end }}
        {{- include "falco.unixSocketVolumeMount"  . | nindent 8 -}}
        {{- with .Values.mounts.volumeMounts }}
          {{- toYaml . | nindent 8 }}
        {{- end }}
  initContainers:
  {{- with .Values.extra.initContainers }}
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- if .Values.driver.enabled }}
  {{- if and .Values.driver.loader.enabled .Values.driver.loader.initContainer.enabled }}
    {{- include "falco.driverLoader.initContainer" . | nindent 4 }}
  {{- end }}
  {{- end }}
  volumes:
    - name: root-falco-fs
      emptyDir: {}
    {{- if .Values.driver.enabled }}  
    - name: boot-fs
      hostPath:
        path: /boot
    - name: lib-modules
      hostPath:
        path: /lib/modules
    - name: usr-fs
      hostPath:
        path: /usr
    - name: etc-fs
      hostPath:
        path: /etc
    {{- end }}
    {{- if and .Values.driver.enabled (eq .Values.driver.kind "module") }}
    - name: dev-fs
      hostPath:
        path: /dev
    {{- end }}
    {{- if and .Values.driver.enabled (and (eq .Values.driver.kind "ebpf") (contains "falco-no-driver" .Values.image.repository)) }}
    - name: debugfs
      hostPath:
        path: /sys/kernel/debug
    {{- end }}
    {{- with .Values.collectors }}
    {{- if .enabled }}
    {{- if .docker.enabled }}
    - name: docker-socket
      hostPath:
        path: {{ .docker.socket }}
    {{- end }}
    {{- if .containerd.enabled }}
    - name: containerd-socket
      hostPath:
        path: {{ .containerd.socket }}
    {{- end }}
    {{- if .crio.enabled }}
    - name: crio-socket
      hostPath:
        path: {{ .crio.socket }}
    {{- end }}
    {{- end }}
    {{- end }}
    {{- if or .Values.driver.enabled .Values.mounts.enforceProcMount }}
    - name: proc-fs
      hostPath:
        path: /proc
    {{- end }}
    - name: runsc-config
      hostPath:
        path: /run/containerd/runsc
    - name: containerd-home
      hostPath:
        path: /home/containerd
    - name: config-volume
      configMap:
        name: {{ include "falco.fullname" . }}
        items:
          - key: falco.yaml
            path: falco.yaml
          - key: falco_rules.yaml
            path: falco_rules.yaml
          - key: falco_rules.local.yaml
            path: falco_rules.local.yaml
          - key: application_rules.yaml
            path: rules.available/application_rules.yaml
          - key: k8s_audit_rules.yaml
            path: k8s_audit_rules.yaml
          - key: aws_cloudtrail_rules.yaml
            path: aws_cloudtrail_rules.yaml
    {{- if .Values.customRules }}
    - name: rules-volume
      configMap:
        name: {{ include "falco.fullname" . }}-rules
    {{- end }}
    {{- if or .Values.certs.existingSecret (and .Values.certs.server.key .Values.certs.server.crt .Values.certs.ca.crt) }}
    - name: certs-volume
      secret:
        {{- if .Values.certs.existingSecret }}
        secretName: {{ .Values.certs.existingSecret }}
        {{- else }}
        secretName: {{ include "falco.fullname" . }}-certs
        {{- end }}
    {{- end }}
    {{- include "falco.unixSocketVolume" . | nindent 4 -}}
    {{- with .Values.mounts.volumes }}
      {{- toYaml . | nindent 4 }}
    {{- end }}
{{- end -}}

{{- define "falco.driverLoader.initContainer" -}}
- name: {{ .Chart.Name }}-driver-loader
  image: {{ include "falco.driverLoader.image" . }}
  imagePullPolicy: {{ .Values.driver.loader.initContainer.image.pullPolicy }}
  {{- with .Values.driver.loader.initContainer.args }}
  args:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.driver.loader.initContainer.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  securityContext:
  {{- if .Values.driver.loader.initContainer.securityContext }}
    {{- toYaml .Values.driver.loader.initContainer.securityContext | nindent 4 }}
  {{- else if eq .Values.driver.kind "module" }}
    privileged: true
  {{- end }}
  volumeMounts:
    - mountPath: /root/.falco
      name: root-falco-fs
    - mountPath: /host/proc
      name: proc-fs
      readOnly: true
    - mountPath: /host/boot
      name: boot-fs
      readOnly: true
    - mountPath: /host/lib/modules
      name: lib-modules
    - mountPath: /host/usr
      name: usr-fs
      readOnly: true
    - mountPath: /host/etc
      name: etc-fs
      readOnly: true
  env:
  {{- if eq .Values.driver.kind "ebpf" }}
    - name: FALCO_BPF_PROBE
      value: {{ .Values.driver.ebpf.path }}
  {{- end }}
  {{- range $key, $value := .Values.driver.loader.initContainer.env }}
    - name: "{{ $key }}"
      value: "{{ $value }}"
  {{- end }}
{{- end -}}

{{- define "falco.securityContext" -}}
{{- $securityContext := dict -}}
{{- if .Values.driver.enabled -}}
  {{- if eq .Values.driver.kind "module" -}}
    {{- $securityContext := set $securityContext "privileged" true -}}
  {{- end -}}
  {{- if eq .Values.driver.kind "ebpf" -}}
    {{- if .Values.driver.ebpf.leastPrivileged -}}
      {{- $securityContext := set $securityContext "capabilities" (dict "add" (list "BPF" "SYS_RESOURCE" "PERFMON" "SYS_PTRACE")) -}}
    {{- else -}}
      {{- $securityContext := set $securityContext "privileged" true -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if not (empty (.Values.containerSecurityContext)) -}}
  {{-  toYaml .Values.containerSecurityContext }}
{{- else -}}
  {{- toYaml $securityContext }}
{{- end -}}
{{- end -}}


{{- define "falco.unixSocketVolumeMount" -}}
{{- if and .Values.falco.grpc.enabled .Values.falco.grpc.bind_address (hasPrefix "unix://" .Values.falco.grpc.bind_address) }}
- mountPath: {{ include "falco.unixSocketDir" . }}
  name: grpc-socket-dir
{{- end }}
{{- end -}}

{{- define "falco.unixSocketVolume" -}}
{{- if and .Values.falco.grpc.enabled .Values.falco.grpc.bind_address (hasPrefix "unix://" .Values.falco.grpc.bind_address) }}
- name: grpc-socket-dir
  hostPath:
    path: {{ include "falco.unixSocketDir" . }}
{{- end }}
{{- end -}}
