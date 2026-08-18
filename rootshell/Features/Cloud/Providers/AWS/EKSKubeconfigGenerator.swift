import Foundation

// MARK: - EKS Kubeconfig Generator

/// Generates kubeconfig YAML for EKS clusters
struct EKSKubeconfigGenerator {

    /// Generate a kubeconfig YAML string for an EKS cluster
    /// - Parameters:
    ///   - clusterName: The EKS cluster name
    ///   - clusterARN: The EKS cluster ARN (used as context/user name)
    ///   - endpoint: The Kubernetes API server endpoint URL
    ///   - certificateAuthorityData: Base64-encoded CA certificate
    ///   - token: Pre-generated EKS authentication token
    /// - Returns: Kubeconfig YAML string
    nonisolated static func generate(
        clusterName: String,
        clusterARN: String,
        endpoint: String,
        certificateAuthorityData: String,
        token: String
    ) -> String {
        // Use cluster ARN as the unique identifier for context/user/cluster names
        // This ensures uniqueness when managing multiple clusters
        let contextName = clusterARN
        let clusterEntryName = clusterARN
        let userName = clusterARN

        return """
apiVersion: v1
kind: Config
preferences: {}

clusters:
- cluster:
    certificate-authority-data: \(certificateAuthorityData)
    server: \(endpoint)
  name: \(clusterEntryName)

contexts:
- context:
    cluster: \(clusterEntryName)
    user: \(userName)
  name: \(contextName)

current-context: \(contextName)

users:
- name: \(userName)
  user:
    token: \(token)
"""
    }

    /// Generate a kubeconfig with exec-based token generation (for reference)
    /// Note: This is not used on iOS as exec is not supported
    /// - Parameters:
    ///   - clusterName: The EKS cluster name
    ///   - clusterARN: The EKS cluster ARN
    ///   - endpoint: The Kubernetes API server endpoint URL
    ///   - certificateAuthorityData: Base64-encoded CA certificate
    ///   - region: AWS region
    /// - Returns: Kubeconfig YAML string with exec configuration
    nonisolated static func generateWithExec(
        clusterName: String,
        clusterARN: String,
        endpoint: String,
        certificateAuthorityData: String,
        region: String
    ) -> String {
        let contextName = clusterARN
        let clusterEntryName = clusterARN
        let userName = clusterARN

        return """
apiVersion: v1
kind: Config
preferences: {}

clusters:
- cluster:
    certificate-authority-data: \(certificateAuthorityData)
    server: \(endpoint)
  name: \(clusterEntryName)

contexts:
- context:
    cluster: \(clusterEntryName)
    user: \(userName)
  name: \(contextName)

current-context: \(contextName)

users:
- name: \(userName)
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: aws
      args:
        - eks
        - get-token
        - --cluster-name
        - \(clusterName)
        - --region
        - \(region)
      env:
        - name: AWS_STS_REGIONAL_ENDPOINTS
          value: regional
      interactiveMode: IfAvailable
      provideClusterInfo: false
"""
    }
}
