// light3-sign — AWS Signature V4 presigning helper for the Light3 Lightroom plugin.
//
// Reads a JSON config from stdin, generates a presigned S3 URL, writes it to stdout.
//
// Input JSON fields:
//
//	endpoint        - e.g. "https://<account>.r2.cloudflarestorage.com"
//	bucket          - e.g. "my-photos"
//	region          - e.g. "auto" (R2) or "us-east-1" (S3)
//	accessKeyId     - S3 access key
//	secretAccessKey - S3 secret key
//	key             - object key, e.g. "galleries/family/photo.jpg"
//	method          - "PUT" or "DELETE"
//	expiresIn       - seconds until the URL expires (default 3600)
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

type input struct {
	Endpoint        string `json:"endpoint"`
	Bucket          string `json:"bucket"`
	Region          string `json:"region"`
	AccessKeyID     string `json:"accessKeyId"`
	SecretAccessKey string `json:"secretAccessKey"`
	Key             string `json:"key"`
	Method          string `json:"method"`
	ExpiresIn       int    `json:"expiresIn"`
}

func main() {
	var in input
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		fmt.Fprintf(os.Stderr, "light3-sign: failed to parse input: %v\n", err)
		os.Exit(1)
	}

	if in.ExpiresIn <= 0 {
		in.ExpiresIn = 3600
	}
	if in.Region == "" {
		in.Region = "auto"
	}

	client := s3.New(s3.Options{
		Region: in.Region,
		Credentials: credentials.NewStaticCredentialsProvider(
			in.AccessKeyID, in.SecretAccessKey, "",
		),
		BaseEndpoint: aws.String(in.Endpoint),
		UsePathStyle: true,
	})

	presigner := s3.NewPresignClient(client)
	ctx := context.Background()
	expires := time.Duration(in.ExpiresIn) * time.Second

	var url string

	switch in.Method {
	case "DELETE":
		res, err := presigner.PresignDeleteObject(ctx,
			&s3.DeleteObjectInput{
				Bucket: aws.String(in.Bucket),
				Key:    aws.String(in.Key),
			},
			s3.WithPresignExpires(expires),
		)
		if err != nil {
			fmt.Fprintf(os.Stderr, "light3-sign: presign failed: %v\n", err)
			os.Exit(1)
		}
		url = res.URL
	default: // PUT
		res, err := presigner.PresignPutObject(ctx,
			&s3.PutObjectInput{
				Bucket: aws.String(in.Bucket),
				Key:    aws.String(in.Key),
			},
			s3.WithPresignExpires(expires),
		)
		if err != nil {
			fmt.Fprintf(os.Stderr, "light3-sign: presign failed: %v\n", err)
			os.Exit(1)
		}
		url = res.URL
	}

	fmt.Print(url)
}
